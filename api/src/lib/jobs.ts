// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Processing jobs: one attempt to turn a ready recording into the followed
 * game video, in the cloud (AWS Batch) or on the user's own computer
 * (docs/CLOUD-PROCESSING-PLAN.md, shared/schemas/job.schema.json).
 *
 * A cloud job is two Batch jobs with the user in between:
 *
 *   queued -> preparing -> needs_answers -> queued -> running -> done
 *                           ^        |
 *                           +- refitting (an answer the engine has to work on:
 *                              the pitch marked, a kit group split, the cameras)
 *
 * The questions and answers are the engine's own files
 * (shared/schemas/engine-questions and engine-answers, the ones the Mac
 * app draws): this server passes them through. The engine decides what is
 * still to ask: `pending` in its questions.json. An answer that needs no
 * work (the pitch approved, the kit groups settled) only closes the check
 * here; the run starts when nothing is open, and the engine applies the
 * answers first. If it then refuses one, it writes its questions again and
 * the job goes back to waiting.
 *
 * The API submits the Batch jobs and owns the record. The engine's
 * container only writes files under the job's output folder and, if it
 * likes, `progress` and `error` on the record; what it produced is read
 * from S3 when Batch says the job ended (onBatchStateChange). This file
 * never touches the engine's code, only its files (docs/LICENSING.md).
 *
 * A recording has at most one job that is not finished: its `activeJobId`,
 * claimed with a conditional write.
 */

import { randomUUID } from 'node:crypto';
import { BatchClient, SubmitJobCommand, TerminateJobCommand } from '@aws-sdk/client-batch';
import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import { GetObjectCommand, HeadObjectCommand, NotFound, NoSuchKey, PutObjectCommand } from '@aws-sdk/client-s3';
import { DeleteCommand, GetCommand, PutCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormatsModule from 'ajv-formats';
import answersSchema from '../../../shared/schemas/engine-answers.schema.json' with { type: 'json' };
import { deployedFootageSigner } from './footageUrls.js';
import { ApiError, badRequest, conflict, forbidden, notFound } from './http.js';
import type { RecordingItem } from './recordings.js';
import { getSettings } from './settings.js';
import { config, ddb, jobPrefix, keys, queryPrefix, recordingPrefix, s3 } from './store.js';

export const batch = new BatchClient({});

export type JobStatus =
  | 'queued'
  | 'preparing'
  | 'needs_answers'
  | 'refitting'
  | 'running'
  | 'done'
  | 'failed'
  | 'cancelled';
export type Command = 'prepare' | 'run' | 'refit';
/** The engine's questions. `cameras` is asked only when the phones' views
 *  couldn't be stitched, and then before the other two. */
export type Check = 'cameras' | 'pitch' | 'kits';
const CHECKS: Check[] = ['cameras', 'pitch', 'kits'];
export type Where = 'cloud' | 'local';

const FINAL: JobStatus[] = ['done', 'failed', 'cancelled'];
export const isFinal = (s: JobStatus) => FINAL.includes(s);

export interface JobError {
  code: string;
  message: string;
}

export interface JobProgress {
  stage: string;
  fraction: number;
  etaSeconds?: number | null;
  at?: string;
}

export interface JobItem {
  pk: string;
  sk: string;
  schemaVersion: 1;
  jobId: string;
  accountId: string;
  gameId: string;
  recordingId: string;
  where: Where;
  status: JobStatus;
  phase: 'prepare' | 'run';
  checks: Partial<Record<Check, 'open' | 'answered'>>;
  progress?: JobProgress | null;
  error?: JobError | null;
  engineVersion?: string | null;
  /** The recording's readyAt when the job started; a later one makes it stale. */
  recordingReadyAt?: string;
  createdAt: string;
  updatedAt: string;
  finishedAt?: string;
  /** The Batch job now working on it, and what it was asked to do. Events
   *  from any other Batch job are ignored. */
  batchJobId?: string;
  batchCommand?: Command;
  batchSubmittedAt?: string;
  /** Seconds of machine time per Batch job, for cost. */
  compute: Record<string, number>;
  /** The consent wording (shared/consent/<version>.md) the user agreed to
   *  when they chose to share a check's result; absent when they didn't.
   *  What the engine then writes to share is filed as a contribution
   *  (lib/jobShares.ts). */
  shareConsent?: Partial<Record<'pitch' | 'kits', string>>;
}

interface JobRef {
  sk: string;
  jobId: string;
  gameId: string;
  recordingId: string;
  createdAt: string;
}

/** The job as the API returns it (shared/schemas/job.schema.json). */
export function jobView(job: JobItem, rec?: Pick<RecordingItem, 'readyAt'>) {
  return {
    schemaVersion: 1 as const,
    jobId: job.jobId,
    gameId: job.gameId,
    recordingId: job.recordingId,
    where: job.where,
    status: job.status,
    phase: job.phase,
    checks: job.checks,
    progress: job.progress ?? null,
    error: job.error ?? null,
    stale: Boolean(rec?.readyAt && job.recordingReadyAt && rec.readyAt !== job.recordingReadyAt),
    engineVersion: job.engineVersion ?? null,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    finishedAt: job.finishedAt ?? null,
  };
}

export type JobView = ReturnType<typeof jobView>;

// --- Reading -----------------------------------------------------------------

async function loadJob(jobId: string) {
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.job(jobId), ConsistentRead: true }));
  return r.Item as JobItem | undefined;
}

async function loadRecording(acct: string, gameId: string, recordingId: string) {
  const r = await ddb.send(
    new GetCommand({ TableName: config.table, Key: keys.recording(acct, gameId, recordingId), ConsistentRead: true }),
  );
  return r.Item as RecordingItem | undefined;
}

/** The job, if it is this account's and for this recording; 404 otherwise. */
export async function getJob(acct: string, gameId: string, recordingId: string, jobId: string): Promise<JobItem> {
  const job = await loadJob(jobId);
  if (!job || job.accountId !== acct || job.gameId !== gameId || job.recordingId !== recordingId) {
    throw notFound('No such job.');
  }
  return job;
}

export async function getJobView(acct: string, gameId: string, recordingId: string, jobId: string) {
  const [job, rec] = await Promise.all([getJob(acct, gameId, recordingId, jobId), loadRecording(acct, gameId, recordingId)]);
  return jobView(job, rec);
}

/** The newest job of each recording in a game, by recording id. */
export async function latestJobs(acct: string, gameId: string): Promise<Map<string, JobItem>> {
  const refs = await queryPrefix<JobRef>(acct, `JOB#${gameId}#`);
  const newest = new Map<string, JobRef>();
  for (const r of refs) {
    const have = newest.get(r.recordingId);
    if (!have || r.createdAt > have.createdAt) newest.set(r.recordingId, r);
  }
  const out = new Map<string, JobItem>();
  await Promise.all(
    [...newest.values()].map(async (r) => {
      const job = await loadJob(r.jobId);
      if (job) out.set(r.recordingId, job);
    }),
  );
  return out;
}

// --- Batch -------------------------------------------------------------------

/** What the engine's container is told (docs/API.md, "The engine's container"). */
async function submit(job: JobItem, command: Command, extraEnv: Record<string, string> = {}) {
  const jobs = config.batchJobs;
  if (!jobs) throw new ApiError(503, 'cloud_unavailable', 'Cloud processing is not set up on this server.');
  const { accountId: acct, gameId, recordingId, jobId } = job;
  const env = {
    OSB_COMMAND: command,
    OSB_JOB_ID: jobId,
    OSB_FOOTAGE_PREFIX: recordingPrefix(acct, gameId, recordingId),
    OSB_OUTPUT_PREFIX: jobPrefix('outputs', acct, gameId, recordingId, jobId),
    OSB_WORK_PREFIX: jobPrefix('work', acct, gameId, recordingId, jobId),
    ...extraEnv,
  };
  const r = await batch.send(
    new SubmitJobCommand({
      // The state-change handler finds the record from this name.
      jobName: batchJobName(command, jobId),
      jobQueue: jobs[command].queue,
      jobDefinition: jobs[command].definition,
      containerOverrides: {
        command: [command],
        environment: Object.entries(env).map(([name, value]) => ({ name, value })),
      },
    }),
  );
  if (!r.jobId) throw new Error('Batch returned no job id');
  return r.jobId;
}

const batchJobName = (command: Command, jobId: string) => `osb-${command}-${jobId}`;
const BATCH_JOB_NAME = /^osb-(prepare|run|refit)-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/;

async function terminate(batchJobId: string, reason: string) {
  try {
    await batch.send(new TerminateJobCommand({ jobId: batchJobId, reason }));
  } catch (e) {
    // The record is already final; a job Batch no longer knows is fine.
    console.warn('could not terminate Batch job', batchJobId, e);
  }
}

// --- Changing state ----------------------------------------------------------

const isConditionFailure = (e: unknown) => e instanceof ConditionalCheckFailedException;

/** Moves a job to a final state, once, and frees its recording for another
 *  job. False when it was already final. */
async function finish(job: JobItem, status: 'done' | 'failed' | 'cancelled', error?: JobError | null) {
  const now = new Date().toISOString();
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.job(job.jobId),
        UpdateExpression: `SET #s = :s, updatedAt = :now, finishedAt = :now${error ? ', #e = :e' : ''}`,
        ConditionExpression: 'attribute_exists(pk) AND NOT (#s IN (:done, :failed, :cancelled))',
        ExpressionAttributeNames: { '#s': 'status', ...(error ? { '#e': 'error' } : {}) },
        ExpressionAttributeValues: {
          ':s': status,
          ':now': now,
          ':done': 'done',
          ':failed': 'failed',
          ':cancelled': 'cancelled',
          ...(error ? { ':e': error } : {}),
        },
      }),
    );
  } catch (e) {
    if (isConditionFailure(e)) return false;
    throw e;
  }
  // The recording keeps pointing at its last job; only a job that isn't
  // final blocks the next one (startJob).
  return true;
}

/** Sets fields while the job is in one of [from]; false when it isn't. */
async function transition(job: JobItem, from: JobStatus[], set: Partial<JobItem>, remove: (keyof JobItem)[] = []) {
  const names: Record<string, string> = { '#status': 'status' };
  const values: Record<string, unknown> = { ':now': new Date().toISOString() };
  const sets = ['updatedAt = :now'];
  for (const [k, v] of Object.entries(set)) {
    names[`#${k}`] = k;
    values[`:${k}`] = v;
    sets.push(`#${k} = :${k}`);
  }
  for (const k of remove) names[`#r_${k}`] = k;
  from.forEach((s, i) => (values[`:from${i}`] = s));
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.job(job.jobId),
        UpdateExpression: `SET ${sets.join(', ')}${remove.length ? ` REMOVE ${remove.map((k) => `#r_${k}`).join(', ')}` : ''}`,
        ConditionExpression: `#status IN (${from.map((_, i) => `:from${i}`).join(', ')})`,
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: values,
      }),
    );
    return true;
  } catch (e) {
    if (isConditionFailure(e)) return false;
    throw e;
  }
}

/** Starts a job for a ready recording. Cloud jobs need the account's
 *  `cloudProcessing` setting; a recording has one unfinished job at most. */
export async function startJob(acct: string, gameId: string, recordingId: string, where: Where) {
  const rec = await loadRecording(acct, gameId, recordingId);
  if (!rec) throw notFound('No such recording.');
  if (rec.status !== 'ready') throw conflict('This recording is still uploading.');
  if (where === 'cloud') {
    if (!(await getSettings(acct)).cloudProcessing) {
      throw new ApiError(403, 'cloud_not_enabled', 'Cloud processing is not switched on for this account.');
    }
    if (!config.batchJobs) throw new ApiError(503, 'cloud_unavailable', 'Cloud processing is not set up on this server.');
  }
  const previous = rec.activeJobId ? await loadJob(rec.activeJobId) : undefined;
  if (previous && !isFinal(previous.status)) throw conflict('This recording is already being processed.');

  const jobId = randomUUID();
  // Claim the recording before the job exists: a claim left pointing at
  // nothing blocks nobody.
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.recording(acct, gameId, recordingId),
        UpdateExpression: 'SET activeJobId = :new',
        ConditionExpression: rec.activeJobId
          ? '#s = :ready AND activeJobId = :old'
          : '#s = :ready AND attribute_not_exists(activeJobId)',
        ExpressionAttributeNames: { '#s': 'status' },
        ExpressionAttributeValues: {
          ':new': jobId,
          ':ready': 'ready',
          ...(rec.activeJobId ? { ':old': rec.activeJobId } : {}),
        },
      }),
    );
  } catch (e) {
    if (isConditionFailure(e)) throw conflict('This recording is already being processed.');
    throw e;
  }

  const now = new Date().toISOString();
  const job: JobItem = {
    ...keys.job(jobId),
    schemaVersion: 1,
    jobId,
    accountId: acct,
    gameId,
    recordingId,
    where,
    // A local job is under way as soon as the app says so.
    status: where === 'cloud' ? 'queued' : 'preparing',
    phase: 'prepare',
    checks: { pitch: 'open', kits: 'open' },
    recordingReadyAt: rec.readyAt,
    createdAt: now,
    updatedAt: now,
    compute: {},
  };
  await ddb.send(new PutCommand({ TableName: config.table, Item: job }));
  await ddb.send(
    new PutCommand({
      TableName: config.table,
      Item: { ...keys.jobRef(acct, gameId, recordingId, jobId), jobId, gameId, recordingId, createdAt: now },
    }),
  );

  if (where === 'cloud') {
    try {
      const batchJobId = await submit(job, 'prepare');
      Object.assign(job, { batchJobId, batchCommand: 'prepare', batchSubmittedAt: now });
      await transition(job, ['queued'], { batchJobId, batchCommand: 'prepare', batchSubmittedAt: now });
    } catch (e) {
      console.error('could not submit the prepare job', e);
      await finish(job, 'failed', { code: 'machine_failed', message: 'The job could not be started.' });
      throw e instanceof ApiError ? e : new ApiError(503, 'cloud_unavailable', 'Cloud processing could not start the job. Try again later.');
    }
  }
  return jobView(job, rec);
}

/** Cancels an unfinished job (the user's Cancel, or a delete). 409 when it
 *  has already finished. */
export async function cancelJob(job: JobItem, error?: JobError) {
  if (!(await finish(job, 'cancelled', error))) throw conflict('This job has already finished.');
  if (job.batchJobId) await terminate(job.batchJobId, error?.message ?? 'Cancelled by the user');
}

/** A recording that is ready a second time (a late Secondary's footage)
 *  cancels the job that started on the first manifest. A finished job is
 *  kept; the website offers to process again (jobView: stale). */
export async function supersedeActiveJob(rec: Pick<RecordingItem, 'activeJobId'>) {
  if (!rec.activeJobId) return;
  const job = await loadJob(rec.activeJobId);
  if (!job || isFinal(job.status)) return;
  try {
    await cancelJob(job, {
      code: 'superseded',
      message: "A second phone's footage arrived after this started. Process the recording again to use both phones.",
    });
  } catch (e) {
    if (!(e instanceof ApiError && e.status === 409)) throw e;
  }
}

/** Ends every unfinished job under an account's sort-key prefix
 *  (`JOB#<gameId>#...`) and removes the job records. The caller deletes
 *  the pointers with the account's other items, and the files. */
export async function deleteJobs(acct: string, skPrefix: string) {
  const refs = await queryPrefix<JobRef>(acct, skPrefix);
  for (const ref of refs) {
    const job = await loadJob(ref.jobId);
    if (job && !isFinal(job.status) && job.batchJobId) await terminate(job.batchJobId, 'The recording was deleted');
    await ddb.send(new DeleteCommand({ TableName: config.table, Key: keys.job(ref.jobId) }));
  }
}

// --- Questions and answers ---------------------------------------------------

const outputKey = (job: JobItem, name: string) =>
  `${jobPrefix('outputs', job.accountId, job.gameId, job.recordingId, job.jobId)}${name}`;
/** The engine's questions.json; every picture it names is next to it, at its path. */
const questionsKey = (job: JobItem) => outputKey(job, 'questions/questions.json');
const answersKey = (job: JobItem) => outputKey(job, 'answers.json');
export const videoKey = (job: JobItem) => outputKey(job, 'game.mp4');

const isMissing = (e: unknown) =>
  e instanceof NoSuchKey || e instanceof NotFound || (e as { name?: string })?.name === 'NoSuchKey' || (e as { name?: string })?.name === 'NotFound';

async function readJson<T>(key: string): Promise<T | undefined> {
  try {
    const r = await s3.send(new GetObjectCommand({ Bucket: config.bucket, Key: key }));
    return JSON.parse(await r.Body!.transformToString()) as T;
  } catch (e) {
    if (isMissing(e)) return undefined;
    throw e;
  }
}

async function head(key: string) {
  try {
    return await s3.send(new HeadObjectCommand({ Bucket: config.bucket, Key: key }));
  } catch (e) {
    if (isMissing(e)) return undefined;
    throw e;
  }
}

/** What this server reads of the engine's questions.json
 *  (shared/schemas/engine-questions.schema.json). */
interface Questions {
  pending: Check[];
  cameras?: { round: number; status: string };
  pitch?: { round: number; status: string; approveAllowed?: boolean; points: Record<string, unknown> };
  kits?: { round: number; status: string; splitAllowed: boolean; groups: { component: number; crops: { id: string }[] }[] };
  [k: string]: unknown;
}

/** The checks as the engine left them: open while it lists the question as pending. */
function checksFrom(q: Questions): JobItem['checks'] {
  const checks: JobItem['checks'] = {};
  for (const c of CHECKS) if (q[c]) checks[c] = q.pending.includes(c) ? 'open' : 'answered';
  if (q.pending.includes('cameras')) {
    // Asked alone; the other two follow once the cameras are known.
    checks.pitch = 'open';
    checks.kits = 'open';
  }
  return checks;
}

/** The fields of the questions that name a picture, relative to the recording. */
const PICTURE_KEYS = new Set(['image', 'overlay', 'background', 'sheet', 'mainLeft', 'secondaryLeft']);

/** Adds a signed `<field>Url` next to every picture the questions name.
 *  The engine's files are not trusted with where they point: a path that
 *  leaves the folder gets null. `panorama` describes the background's
 *  pixels and names no file of its own. */
function withPictureUrls(node: unknown, sign: (relative: string) => string): unknown {
  if (Array.isArray(node)) return node.map((n) => withPictureUrls(n, sign));
  if (typeof node !== 'object' || node === null) return node;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(node)) {
    if (k === 'panorama') {
      out[k] = v;
      continue;
    }
    out[k] = withPictureUrls(v, sign);
    if (PICTURE_KEYS.has(k) && typeof v === 'string') {
      const safe = v.length > 0 && !v.startsWith('/') && !v.split('/').some((part) => part === '..' || part === '');
      out[`${k}Url`] = safe ? sign(v) : null;
    }
  }
  return out;
}

/** The engine's questions with links to their pictures, and which checks
 *  are still open. 409 before the engine has written any. */
export async function questionsView(job: JobItem) {
  const q = await readJson<Questions>(questionsKey(job));
  if (!q) throw conflict('This job has no questions yet.');
  const signer = await deployedFootageSigner();
  const expiresAt = new Date(Date.now() + config.downloadUrlTtlSeconds * 1000);
  const dir = questionsKey(job).replace(/questions\.json$/, '');
  return {
    status: job.status,
    checks: job.checks,
    expiresAt: expiresAt.toISOString(),
    questions: withPictureUrls(q, (relative) => signer.url(dir + relative, expiresAt)),
  };
}

// ajv-formats is CommonJS; its default export arrives wrapped under ESM.
const addFormats = ((addFormatsModule as unknown as { default?: unknown }).default ??
  addFormatsModule) as (ajv: Ajv2020) => Ajv2020;
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
ajv.addSchema(answersSchema);
const validators = Object.fromEntries(
  CHECKS.map((c) => [c, ajv.getSchema(`${answersSchema.$id}#/properties/${c}`)!]),
) as Record<Check, NonNullable<ReturnType<typeof ajv.getSchema>>>;

interface CamerasAnswer {
  round: number;
  leftPhone: 'main' | 'secondary';
}
interface PitchAnswer {
  round: number;
  approve?: true;
  points?: Record<string, unknown>;
  share?: boolean;
}
interface KitsAnswer {
  round: number;
  tapped?: Record<string, string[]>;
  merge?: number[][];
  split?: number | null;
  keeperOrReferee?: number[];
  notKit?: number[];
  share?: boolean;
}
type Answer = CamerasAnswer | PitchAnswer | KitsAnswer;

const invalid = (message: string) => new ApiError(400, 'invalid_answers', message);

/** The consent wordings a share may be made under (shared/consent/<version>.md;
 *  the same list as lib/contributions.ts, which files what is shared). */
export const SHARE_CONSENT_VERSIONS = ['share-v1'] as const;

/** Rules the schema can't express: the answer is to the question as it
 *  stands, and names things the question has. */
function checkAgainstQuestions(check: Check, answer: Answer, q: Questions) {
  const asked = q[check] as { round: number } | undefined;
  if (!asked || !q.pending.includes(check) || answer.round !== asked.round) {
    throw conflict('These questions have changed since you opened them. Reload and answer again.');
  }
  if (check === 'pitch') {
    const a = answer as PitchAnswer;
    if (a.approve && q.pitch!.approveAllowed === false) {
      throw invalid('The pitch has to be marked before it can be approved: the cameras are fitted from the marked points.');
    }
    const unknown = Object.keys(a.points ?? {}).filter((name) => !(name in q.pitch!.points));
    if (unknown.length) throw invalid(`The question has no pitch point called "${unknown[0]}".`);
  } else if (check === 'kits') {
    const a = answer as KitsAnswer;
    const crops = new Map(q.kits!.groups.map((g) => [g.component, new Set(g.crops.map((c) => c.id))]));
    const named = [...(a.merge ?? []).flat(), ...(a.keeperOrReferee ?? []), ...(a.notKit ?? []), ...(a.split != null ? [a.split] : [])];
    if (named.some((c) => !crops.has(c))) throw invalid('An answer names a kit group the question does not have.');
    for (const [group, ids] of Object.entries(a.tapped ?? {})) {
      const have = crops.get(Number(group));
      if (!have || ids.some((id) => !have.has(id))) throw invalid('An answer names a person the question does not have.');
    }
    if (a.split != null && !q.kits!.splitAllowed) throw invalid('A group can only be split once.');
  }
}

/** Whether the engine has to work on an answer before anything else can be
 *  asked: it draws the pitch or the groups again from it. */
const needsEngine = (check: Check, a: Answer) =>
  check === 'cameras' || (check === 'pitch' && !(a as PitchAnswer).approve) || (check === 'kits' && (a as KitsAnswer).split != null);

/** Records the answer to one question (body: `question`, plus that
 *  question's answer from engine-answers.schema.json). An approved pitch
 *  or settled kit groups close the check, and the run starts when none is
 *  open. A marked pitch, a group to split or the cameras start a refit,
 *  after which the engine's questions say what is still open. */
export async function answerCheck(job: JobItem, input: Record<string, unknown>) {
  const { question, consentVersion, ...answer } = input;
  const check = question as Check;
  if (!CHECKS.includes(check)) throw badRequest('"question" must be "cameras", "pitch" or "kits".');
  if (job.where !== 'cloud') throw forbidden('A job on your own computer is answered in its app.');
  if (job.status !== 'needs_answers') throw conflict('This job is not waiting for answers.');
  if (job.checks[check] !== 'open') throw conflict('This check is already answered.');
  const validate = validators[check];
  if (!validate(answer)) {
    throw new ApiError(
      400,
      'invalid_answers',
      'The answer does not match the schema.',
      (validate.errors ?? []).map((e) => `${e.instancePath || '/'} ${e.message ?? ''}`.trim()),
    );
  }
  const q = await readJson<Questions>(questionsKey(job));
  if (!q) throw conflict('This job has no questions yet.');
  const a = answer as unknown as Answer;
  checkAgainstQuestions(check, a, q);
  // Sharing a result to improve the models is the user's own choice, made
  // where they are asked: never by leaving a field out, and only with the
  // wording they were shown.
  let shareConsent = job.shareConsent;
  if (check !== 'cameras') {
    const sharing = (a as PitchAnswer).share === true;
    if (sharing && !(SHARE_CONSENT_VERSIONS as readonly unknown[]).includes(consentVersion)) {
      throw invalid(`Sharing needs "consentVersion": the wording that was agreed to (${SHARE_CONSENT_VERSIONS.join(', ')}).`);
    }
    (a as PitchAnswer).share = sharing;
    shareConsent = { ...job.shareConsent };
    if (sharing) shareConsent[check] = consentVersion as string;
    else delete shareConsent[check];
  }

  const refit = needsEngine(check, a);
  const checks = { ...job.checks, [check]: refit ? 'open' : 'answered' } as JobItem['checks'];
  const run = !refit && Object.values(checks).every((c) => c === 'answered');

  // The state first, so two answers at once can't both start a Batch job.
  const next: Partial<JobItem> = {
    ...(refit ? { status: 'refitting' as const } : run ? { status: 'queued' as const, phase: 'run' as const } : {}),
    checks,
    shareConsent: shareConsent ?? {},
  };
  if (!(await transition(job, ['needs_answers'], next, ['progress']))) {
    throw conflict('This job is not waiting for answers.');
  }

  try {
    const now = new Date().toISOString();
    const answers = (await readJson<Record<string, unknown>>(answersKey(job))) ?? {};
    answers[check] = a;
    await s3.send(
      new PutObjectCommand({
        Bucket: config.bucket,
        Key: answersKey(job),
        Body: JSON.stringify(answers),
        ContentType: 'application/json',
      }),
    );
    if (refit || run) {
      const command: Command = refit ? 'refit' : 'run';
      const batchJobId = await submit(job, command);
      await transition(job, [refit ? 'refitting' : 'queued'], { batchJobId, batchCommand: command, batchSubmittedAt: now });
    }
  } catch (e) {
    console.error('could not record the answer or start the next step', e);
    await transition(job, ['refitting', 'queued', 'needs_answers'], {
      status: 'needs_answers',
      phase: 'prepare',
      checks: job.checks,
      shareConsent: job.shareConsent ?? {},
    });
    throw e instanceof ApiError ? e : new ApiError(503, 'cloud_unavailable', 'Your answer could not be saved. Try again.');
  }
  return jobView({ ...job, ...next, updatedAt: new Date().toISOString(), progress: null });
}

/** A signed link to the finished game video. */
export async function videoLink(job: JobItem) {
  if (job.status !== 'done') throw conflict('This job has no video yet.');
  const h = await head(videoKey(job));
  if (!h) throw notFound('The video is no longer stored.');
  const signer = await deployedFootageSigner();
  const expiresAt = new Date(Date.now() + config.downloadUrlTtlSeconds * 1000);
  return {
    expiresAt: expiresAt.toISOString(),
    video: { url: signer.url(videoKey(job), expiresAt), bytes: h.ContentLength ?? null, fileName: 'game.mp4' },
  };
}

// --- Local jobs --------------------------------------------------------------

const LOCAL_STATUSES: JobStatus[] = ['preparing', 'needs_answers', 'refitting', 'running', 'done', 'failed'];

/** The app running a job on the user's own computer reports where it is. */
export async function reportLocal(job: JobItem, input: Record<string, unknown>) {
  if (job.where !== 'local') throw forbidden('Only a job on your own computer is reported this way.');
  const status = input.status as JobStatus;
  if (!LOCAL_STATUSES.includes(status)) throw badRequest(`"status" must be one of ${LOCAL_STATUSES.join(', ')}.`);
  const set: Partial<JobItem> = {};
  if (input.progress !== undefined && input.progress !== null) {
    const p = input.progress as Record<string, unknown>;
    if (typeof p.stage !== 'string' || p.stage.length > 100 || typeof p.fraction !== 'number' || p.fraction < 0 || p.fraction > 1) {
      throw badRequest('"progress" needs a stage and a fraction from 0 to 1.');
    }
    set.progress = {
      stage: p.stage,
      fraction: p.fraction,
      etaSeconds: typeof p.etaSeconds === 'number' && p.etaSeconds >= 0 ? p.etaSeconds : null,
      at: new Date().toISOString(),
    };
  }
  if (typeof input.engineVersion === 'string' && input.engineVersion.length <= 200) set.engineVersion = input.engineVersion;
  let error: JobError | undefined;
  if (status === 'failed') {
    const e = (input.error ?? {}) as Record<string, unknown>;
    error = {
      code: typeof e.code === 'string' ? e.code.slice(0, 100) : 'engine_failed',
      message: typeof e.message === 'string' ? e.message.slice(0, 1000) : 'Processing failed.',
    };
  }
  const notFinal = LOCAL_STATUSES.filter((s) => !isFinal(s));
  if (status === 'done' || status === 'failed') {
    if (Object.keys(set).length) await transition(job, notFinal, set);
    if (!(await finish(job, status, error))) throw conflict('This job has already finished.');
  } else {
    const phase = status === 'running' ? 'run' : 'prepare';
    if (!(await transition(job, notFinal, { ...set, status, phase }))) throw conflict('This job has already finished.');
  }
  return jobView((await loadJob(job.jobId))!);
}

// --- Batch state changes -----------------------------------------------------

export interface BatchStateChange {
  jobName: string;
  jobId: string;
  status: string;
  statusReason?: string;
  attempts?: { startedAt?: number; stoppedAt?: number }[];
  container?: { exitCode?: number; reason?: string };
}

export type JobEvent = { job: JobItem; kind: 'check' | 'done' | 'failed' };

/** Nothing is left to ask after a prepare or a refit: the run starts. */
async function startRun(job: JobItem, checks: JobItem['checks']): Promise<JobEvent | null> {
  const now = new Date().toISOString();
  if (!(await transition(job, ['queued', 'preparing', 'refitting'], { status: 'queued', phase: 'run', checks }, ['progress']))) {
    return null;
  }
  try {
    const batchJobId = await submit(job, 'run');
    await transition(job, ['queued'], { batchJobId, batchCommand: 'run', batchSubmittedAt: now });
    return null;
  } catch (e) {
    console.error('could not submit the run', e);
    const error = { code: 'machine_failed', message: 'The video could not be started. Try again.' };
    return (await finish(job, 'failed', error)) ? { job: { ...job, error }, kind: 'failed' } : null;
  }
}

/** Follows a Batch job of ours: started, or ended with what it left in S3.
 *  Returns what the user should hear about, if anything. Safe to run twice
 *  for the same event. */
export async function onBatchStateChange(d: BatchStateChange): Promise<JobEvent | null> {
  const m = BATCH_JOB_NAME.exec(d.jobName);
  if (!m) return null;
  const command = m[1] as Command;
  const job = await loadJob(m[2]!);
  // A Batch job we replaced or cancelled no longer speaks for the record.
  if (!job || job.batchJobId !== d.jobId) return null;

  if (d.status === 'RUNNING') {
    if (command !== 'refit') await transition(job, ['queued'], { status: command === 'prepare' ? 'preparing' : 'running' });
    return null;
  }
  if (d.status !== 'SUCCEEDED' && d.status !== 'FAILED') return null;

  const seconds = (d.attempts ?? []).reduce(
    (n, a) => n + (a.startedAt && a.stoppedAt ? Math.max(0, a.stoppedAt - a.startedAt) / 1000 : 0),
    0,
  );
  await ddb.send(
    new UpdateCommand({
      TableName: config.table,
      Key: keys.job(job.jobId),
      UpdateExpression: 'SET compute.#b = :s',
      ConditionExpression: 'attribute_exists(pk)',
      ExpressionAttributeNames: { '#b': d.jobId },
      ExpressionAttributeValues: { ':s': Math.round(seconds) },
    }),
  );
  if (isFinal(job.status)) return null;

  if (d.status === 'SUCCEEDED') {
    if (command === 'run' && (await head(videoKey(job)))) {
      return (await finish(job, 'done')) ? { job, kind: 'done' } : null;
    }
    // prepare, a refit, or a run the engine would not start (it refused an
    // answer): its questions, written by this Batch job, say what is open.
    const written = await head(questionsKey(job));
    const fresh =
      written &&
      (command === 'prepare' || !job.batchSubmittedAt || (written.LastModified?.getTime() ?? 0) >= Math.floor(Date.parse(job.batchSubmittedAt) / 1000) * 1000);
    const q = fresh ? await readJson<Questions>(questionsKey(job)) : undefined;
    if (q && Array.isArray(q.pending)) {
      const checks = checksFrom(q);
      if (q.pending.length === 0 && command !== 'run') return startRun(job, checks);
      if (q.pending.length > 0) {
        const moved = await transition(
          job,
          ['queued', 'preparing', 'refitting', 'running'],
          { status: 'needs_answers', phase: 'prepare', checks },
          ['progress'],
        );
        return moved && command === 'prepare' ? { job, kind: 'check' } : null;
      }
    }
    const error = { code: 'engine_no_result', message: 'Processing ended without a result.' };
    return (await finish(job, 'failed', error)) ? { job: { ...job, error }, kind: 'failed' } : null;
  }

  // FAILED. The engine's own error, if it left one, says more than Batch does.
  const latest = (await loadJob(job.jobId)) ?? job;
  const reason = `${d.statusReason ?? ''} ${d.container?.reason ?? ''}`;
  const error =
    latest.error ??
    (/timed? ?out/i.test(reason)
      ? { code: 'timed_out', message: 'Processing took too long and was stopped.' }
      : /capacity|misconfiguration/i.test(reason)
        ? { code: 'no_machine', message: 'No machine became free to process this game. Try again later.' }
        : /host ec2|spot|instance/i.test(reason)
          ? { code: 'machine_failed', message: 'The machine processing this game was taken away too many times.' }
          : { code: 'engine_failed', message: 'Processing stopped with an error.' });
  return (await finish(job, 'failed', error)) ? { job: { ...job, error }, kind: 'failed' } : null;
}
