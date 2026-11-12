// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

// A stand-in for the engine's container, so cloud processing can be
// deployed and tried end to end before the real engine exists. It keeps
// the container's side of the contract (docs/API.md, "The engine's
// container"), in the real engine's formats: it reads the job from OSB_*
// variables, writes questions/questions.json (engine-questions) or
// game.mp4 under the output prefix, applies answers.json (engine-answers),
// reports progress on the job record, and exits 0 or non-zero. It reads
// no footage beyond checking the manifest is there.
//
//   node stub.mjs prepare | refit | run
//
// OSB_STUB_SECONDS  how long a command pretends to work (default 20)
// OSB_STUB_FAIL     fail with this error code instead of finishing

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { GetObjectCommand, HeadObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { DynamoDBDocumentClient, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { FIRST_FIT, FIRST_GROUPS, PANORAMA, kitFiles, linesPx, pitchSvg, splitGroup, toDeg, toPx } from './scene.mjs';
import { VIDEO_BASE64 } from './video.mjs';

const ENGINE_VERSION = 'stub-engine 0.1.0';
const command = process.argv[2] ?? process.env.OSB_COMMAND;
const env = (name) => {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
};
const s3 = new S3Client({ forcePathStyle: process.env.S3_FORCE_PATH_STYLE === '1' });
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const bucket = env('OSB_BUCKET');
const table = env('OSB_TABLE');
const jobId = env('OSB_JOB_ID');
const out = env('OSB_OUTPUT_PREFIX');
const work = env('OSB_WORK_PREFIX');
const seconds = Number(process.env.OSB_STUB_SECONDS ?? 20);

const say = (event) => console.log(JSON.stringify(event));
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const TYPES = { json: 'application/json', svg: 'image/svg+xml', mp4: 'video/mp4' };
const put = (key, body) =>
  s3.send(new PutObjectCommand({ Bucket: bucket, Key: key, Body: body, ContentType: TYPES[key.split('.').pop()] }));

async function getJson(key) {
  try {
    const r = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    return JSON.parse(await r.Body.transformToString());
  } catch (e) {
    if (e.name === 'NoSuchKey' || e.name === 'NotFound') return undefined;
    throw e;
  }
}

/** Writes to the job record only while it exists: a deleted job is left deleted. */
async function update(expression, names, values) {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: table,
        Key: { pk: `JOB#${jobId}`, sk: 'JOB' },
        UpdateExpression: expression,
        ConditionExpression: 'attribute_exists(pk)',
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: values,
      }),
    );
  } catch (e) {
    if (e.name !== 'ConditionalCheckFailedException') throw e;
  }
}

async function progress(stage, fraction, etaSeconds = null) {
  say({ event: 'progress', stage, fraction, etaSeconds });
  await update(
    'SET progress = :p, engineVersion = :v',
    undefined,
    { ':p': { stage, fraction, etaSeconds, at: new Date().toISOString() }, ':v': ENGINE_VERSION },
  );
}

class EngineError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/** The recording was deleted (or never finished uploading) if its manifest is gone. */
async function requireManifest() {
  try {
    await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: `${env('OSB_FOOTAGE_PREFIX')}manifest.json` }));
  } catch (e) {
    if (e.name === 'NotFound' || e.name === 'NoSuchKey') throw new EngineError('footage_missing', "The recording's footage is no longer there.");
    throw e;
  }
}

/** Pretends to work through [stages], from [from] (0..1) of the way. */
async function pretend(stages, from = 0, checkpoint) {
  const steps = stages.length * 4;
  for (let i = Math.floor(from * steps); i < steps; i++) {
    const fraction = i / steps;
    await progress(stages[Math.floor(i / 4)], fraction, Math.round(seconds * (1 - fraction)));
    await sleep(seconds / steps);
    if (process.env.OSB_STUB_FAIL && fraction >= 0.5) throw new EngineError(process.env.OSB_STUB_FAIL, 'The stub engine was told to fail.');
    if (checkpoint) await checkpoint((i + 1) / steps);
  }
}

const ASK_PITCH =
  'This is the empty pitch with our fitted lines drawn in red. Do the red lines sit on the painted lines? ' +
  'If not, give each named point where it really is, or say it cannot be seen.';
const ASK_KITS =
  'Each group should be one kit and every kit one group. Name anyone in the wrong group, then say whether ' +
  'groups are the same kit, one group holds two kits, and which groups are keepers, the referee or not a kit.';

const pending = (st) => ['pitch', 'kits'].filter((n) => st[n].status === 'pending');

/** questions.json as the real engine writes it, and its pictures, at the
 *  paths it names them by. */
async function writeQuestions(st) {
  const kits = kitFiles(st.kits.groups, st.kits.round);
  await put(`${out}questions/pitch/background.svg`, pitchSvg());
  await put(`${out}questions/pitch/overlay.svg`, pitchSvg(st.pitch.points));
  await Promise.all(kits.files.map((f) => put(`${out}questions/${f.path}`, f.body)));
  await put(
    `${out}questions/questions.json`,
    JSON.stringify({
      schemaVersion: 1,
      recording: '.',
      pending: pending(st),
      pitch: {
        round: st.pitch.round,
        status: st.pitch.status,
        background: 'pitch/background.svg',
        overlay: 'pitch/overlay.svg',
        panorama: PANORAMA,
        fit: { lengthM: 100, widthM: 64, cameraHeightM: 3, fittedWith: st.pitch.round > 1 ? 'lines+taps' : 'lines' },
        lines: linesPx(st.pitch.points).map((l) => l.map((p) => [toDeg(p).yaw, toDeg(p).pitch])),
        goals: [],
        points: Object.fromEntries(Object.entries(st.pitch.points).map(([name, p]) => [name, toDeg(p)])),
        ask: ASK_PITCH,
      },
      kits: {
        round: st.kits.round,
        status: st.kits.status,
        k: st.kits.groups.length,
        splitAllowed: st.kits.splitAllowed,
        groups: kits.groups,
        ask: ASK_KITS,
        ...(st.kits.problem ? { problem: st.kits.problem } : {}),
      },
    }),
  );
  // What the next command starts from.
  await put(`${work}state.json`, JSON.stringify(st));
  say({ event: 'questions', pending: pending(st) });
}

/** Applies answers.json as the engine's prepare does: an answer to an
 *  earlier round is ignored. */
function applyAnswers(st, answers) {
  const a = answers?.pitch;
  if (a && a.round === st.pitch.round && st.pitch.status === 'pending') {
    if (a.approve) st.pitch.status = 'approved';
    else if (a.points) {
      // The "refit": the lines go through the points the user placed.
      for (const [name, p] of Object.entries(a.points)) {
        if (typeof p.yaw === 'number' && st.pitch.points[name]) st.pitch.points[name] = toPx(p);
      }
      st.pitch.round += 1;
    }
  }
  const k = answers?.kits;
  if (k && k.round === st.kits.round && st.kits.status === 'pending') {
    delete st.kits.problem;
    const out = new Set([...(k.keeperOrReferee ?? []), ...(k.notKit ?? [])]);
    const merged = (k.merge ?? []).reduce((n, set) => n + set.length - 1, 0);
    if (k.split != null && st.kits.splitAllowed) {
      st.kits.groups = splitGroup(st.kits.groups, k.split);
      st.kits.splitAllowed = false;
      st.kits.round += 1;
    } else if (k.keeperOrReferee && st.kits.groups.length - out.size - merged < 2) {
      st.kits.round += 1;
      st.kits.problem = 'fewer than two kit groups left: merge fewer, or mark fewer as not a kit';
    } else st.kits.status = 'answered';
  }
}

const loadState = async () => (await getJson(`${work}state.json`)) ?? null;

async function prepare() {
  await requireManifest();
  await pretend(['sync', 'pitch', 'kits']);
  await writeQuestions({
    pitch: { round: 1, status: 'pending', points: FIRST_FIT },
    kits: { round: 1, status: 'pending', groups: FIRST_GROUPS, splitAllowed: true },
  });
}

async function refit() {
  const st = await loadState();
  const answers = await getJson(`${out}answers.json`);
  if (!st || !answers) throw new EngineError('nothing_to_refit', 'There is no answer to apply.');
  await progress('pitch', 0.5);
  await sleep(Math.min(seconds, 5));
  applyAnswers(st, answers);
  await writeQuestions(st);
}

async function run() {
  await requireManifest();
  const st = await loadState();
  if (!st) throw new EngineError('needs_answers', 'The run was started before the game was prepared.');
  applyAnswers(st, await getJson(`${out}answers.json`));
  if (pending(st).length) {
    // An answer the engine can't use: ask again instead of making the video.
    await writeQuestions(st);
    return;
  }
  await put(`${work}state.json`, JSON.stringify(st));
  // Resume where a reclaimed Spot instance left off.
  const done = (await getJson(`${work}checkpoint.json`))?.fraction ?? 0;
  if (done > 0) console.log(`resuming from ${Math.round(done * 100)}%`);
  await pretend(['ball', 'roles', 'render', 'upload'], done, async (fraction) => {
    await put(`${work}checkpoint.json`, JSON.stringify({ fraction }));
  });
  await requireManifest();
  await put(`${out}game.mp4`, Buffer.from(VIDEO_BASE64, 'base64'));
  await put(`${out}result.json`, JSON.stringify({ event: 'done', output: 'game.mp4', ballAimShare: 0.5, ballLow: false }));
  await progress('upload', 1, 0);
  say({ event: 'done', output: 'game.mp4' });
}

try {
  const commands = { prepare, refit, run };
  if (!commands[command]) throw new Error(`unknown command "${command}": use prepare, refit or run`);
  await commands[command]();
} catch (e) {
  const error = { code: e instanceof EngineError ? e.code : 'stub_crashed', message: String(e.message ?? e) };
  say({ event: 'error', ...error });
  if (!(e instanceof EngineError)) console.error(e);
  await update('SET #e = :e', { '#e': 'error' }, { ':e': error }).catch(() => {});
  process.exit(1);
}
