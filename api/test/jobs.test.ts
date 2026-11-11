// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { SubmitJobCommand, TerminateJobCommand } from '@aws-sdk/client-batch';
import { AdminDeleteUserCommand, AdminGetUserCommand } from '@aws-sdk/client-cognito-identity-provider';
import { GetObjectCommand, ListObjectsV2Command, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { SendEmailCommand } from '@aws-sdk/client-sesv2';
import { PutParameterCommand, SSMClient } from '@aws-sdk/client-ssm';
import { GetCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { mockClient } from 'aws-sdk-client-mock';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { handler as admin } from '../src/handlers/admin.js';
import { handler as batchEvent } from '../src/handlers/jobs.js';
import { ses } from '../src/lib/email.js';
import { batch } from '../src/lib/jobs.js';
import { cognito, config, ddb, keys, queryPrefix } from '../src/lib/store.js';
import { callDevice, callWeb, deviceEntry, linkPhone, manifest, resetAws, uploadFile, type Phone } from './helpers.js';

const s3 = new S3Client({ forcePathStyle: true });
const batchMock = mockClient(batch);
const sesMock = mockClient(ses);
const cognitoMock = mockClient(cognito);

const CDN = 'd222.cloudfront.net';
const BATCH_JOBS = {
  prepare: { queue: 'gpu-queue', definition: 'prepare-def' },
  run: { queue: 'gpu-queue', definition: 'run-def' },
  refit: { queue: 'cpu-queue', definition: 'refit-def' },
};

const QUESTIONS = (jobId: string, round = 1, canSplit = true) => ({
  schemaVersion: 1,
  jobId,
  engineVersion: 'stub 0',
  pitch: {
    round,
    text: 'Do the drawn lines sit on the painted lines?',
    image: 'pitch.jpg',
    width: 2000,
    height: 600,
    lines: [
      [
        [100, 400],
        [1900, 400],
      ],
    ],
    keypoints: [
      { id: 'near_left_corner', label: 'Near left corner', x: 100, y: 400 },
      { id: 'near_right_corner', label: 'Near right corner', x: 1900, y: 400 },
    ],
  },
  kits: {
    round: 1,
    text: 'Tap anyone in the wrong group.',
    canSplit,
    groups: [
      { id: 'g0', people: [{ id: 'p0', image: 'kits/g0/p0.jpg' }, { id: 'p1', image: '../../../secret.jpg' }] },
      { id: 'g1', people: [{ id: 'p0', image: 'kits/g1/p0.jpg' }] },
    ],
  },
});

async function setCloud(accountId: string, enabled: unknown, groups = '[admins]') {
  const r = await admin({
    routeKey: 'PUT /admin/accounts/{accountId}/cloud-processing',
    pathParameters: { accountId },
    body: JSON.stringify({ enabled }),
    isBase64Encoded: false,
    requestContext: { authorizer: { jwt: { claims: { sub: randomUUID(), 'cognito:groups': groups }, scopes: [] } } },
  } as any);
  return { status: r.statusCode, body: r.body ? JSON.parse(r.body) : undefined };
}

describe('processing jobs', () => {
  let alice: string;
  let main: Phone;
  let gameId: string;
  let recordingId: string;
  let batchIds: string[];
  const mainFiles = [randomBytes(250), randomBytes(120)];
  const recPath = () => ({ gameId, recordingId });
  const jobPath = (jobId: string) => ({ gameId, recordingId, jobId });
  const outputs = (jobId: string) => `outputs/${alice}/games/${gameId}/recordings/${recordingId}/jobs/${jobId}/`;
  const work = (jobId: string) => `work/${alice}/games/${gameId}/recordings/${recordingId}/jobs/${jobId}/`;

  const start = (acct = alice, where = 'cloud') =>
    callWeb(acct, 'POST /games/{gameId}/recordings/{recordingId}/jobs', { path: recPath(), body: { where } });
  const get = (jobId: string, acct = alice) =>
    callWeb(acct, 'GET /games/{gameId}/recordings/{recordingId}/jobs/{jobId}', { path: jobPath(jobId) });
  const answer = (jobId: string, body: unknown) =>
    callWeb(alice, 'PUT /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/answers', { path: jobPath(jobId), body });
  const put = (key: string, body: string | Buffer = 'x') =>
    s3.send(new PutObjectCommand({ Bucket: config.bucket, Key: key, Body: body }));
  const keysUnder = async (prefix: string) =>
    ((await s3.send(new ListObjectsV2Command({ Bucket: config.bucket, Prefix: prefix }))).Contents ?? []).map((o) => o.Key);
  const submits = () => batchMock.commandCalls(SubmitJobCommand).map((c) => c.args[0].input);
  const emails = () => sesMock.commandCalls(SendEmailCommand).map((c) => c.args[0].input.Content!.Simple!.Subject!.Data);

  /** Set to make Batch refuse the next job once. */
  let refuseNext: Error | null = null;
  const nextBatchJob = () => {
    if (refuseNext) {
      const e = refuseNext;
      refuseNext = null;
      throw e;
    }
    batchIds.push(`batch-${batchIds.length}`);
    return { jobId: batchIds.at(-1), jobName: 'x' };
  };

  /** What Batch tells EventBridge about the [n]th job we submitted. */
  const event = (command: string, jobId: string, status: string, n = batchIds.length - 1, extra: object = {}) =>
    batchEvent({
      detail: {
        jobName: `osb-${command}-${jobId}`,
        jobId: batchIds[n]!,
        status,
        attempts: status === 'RUNNING' ? [] : [{ startedAt: 1_000_000, stoppedAt: 1_090_000 }],
        ...extra,
      },
    } as any);

  async function makeReady() {
    await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
      path: recPath(),
      body: manifest(gameId, recordingId, main, mainFiles),
    });
    for (const [i, f] of mainFiles.entries()) expect((await uploadFile(main, gameId, recordingId, i, f)).status).toBe(200);
  }

  /** A cloud job taken as far as waiting for answers. */
  async function prepared() {
    const jobId = (await start()).body.jobId as string;
    await event('prepare', jobId, 'RUNNING');
    await put(`${outputs(jobId)}questions/questions.json`, JSON.stringify(QUESTIONS(jobId)));
    await event('prepare', jobId, 'SUCCEEDED');
    return jobId;
  }

  const approve = { check: 'pitch', round: 1, approved: true };
  const kitsOk = { check: 'kits', round: 1, wrong: [{ groupId: 'g0', personId: 'p1' }], structure: { kind: 'ok' } };

  beforeAll(async () => {
    const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
    process.env.FOOTAGE_CDN_DOMAIN = CDN;
    process.env.FOOTAGE_KEY_PAIR_ID = 'K2JOBS';
    process.env.FOOTAGE_SIGNING_KEY_PARAM = '/osb-test/jobs-signing-key';
    process.env.BATCH_JOBS = JSON.stringify(BATCH_JOBS);
    process.env.SITE_URL = 'https://osb.example.com';
    process.env.EMAIL_FROM = 'OpenSportsBall <no-reply@osb.example.com>';
    process.env.USER_POOL_ID = 'pool-1';
    await new SSMClient({}).send(
      new PutParameterCommand({
        Name: '/osb-test/jobs-signing-key',
        Type: 'SecureString',
        Overwrite: true,
        Value: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
      }),
    );
  });

  beforeEach(async () => {
    await resetAws();
    batchIds = [];
    refuseNext = null;
    batchMock.reset();
    batchMock.on(SubmitJobCommand).callsFake(nextBatchJob);
    batchMock.on(TerminateJobCommand).resolves({});
    sesMock.reset();
    sesMock.on(SendEmailCommand).resolves({});
    cognitoMock.reset();
    cognitoMock.on(AdminGetUserCommand).resolves({ UserAttributes: [{ Name: 'email', Value: 'alice@example.com' }] });
    cognitoMock.on(AdminDeleteUserCommand).resolves({});
    alice = randomUUID();
    main = await linkPhone(alice);
    gameId = randomUUID();
    recordingId = randomUUID();
    await makeReady();
    expect((await setCloud(alice, true)).status).toBe(200);
  });

  describe('who may start one', () => {
    it('an admin switches cloud processing on per account, and /me says so', async () => {
      const bob = randomUUID();
      expect((await callWeb(bob, 'GET /me')).body.cloudProcessing).toBe(false);
      expect((await setCloud(bob, true, '[coaches]')).status).toBe(403);
      expect((await setCloud(bob, 'yes')).status).toBe(400);
      expect((await setCloud(bob, true)).body).toEqual({ accountId: bob, cloudProcessing: true });
      expect((await callWeb(bob, 'GET /me')).body.cloudProcessing).toBe(true);
      expect((await setCloud(bob, false)).status).toBe(200);
      expect((await callWeb(bob, 'GET /me')).body.cloudProcessing).toBe(false);
    });

    it('refuses the cloud for an account without it, but not a local job', async () => {
      await setCloud(alice, false);
      const r = await start();
      expect(r.status).toBe(403);
      expect(r.body.error).toBe('cloud_not_enabled');
      expect(submits()).toHaveLength(0);
      expect((await start(alice, 'local')).status).toBe(201);
    });

    it('needs a ready recording of the account', async () => {
      expect((await start(randomUUID())).status).toBe(404);
      recordingId = randomUUID();
      await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
        path: recPath(),
        body: manifest(gameId, recordingId, main, mainFiles),
      });
      expect((await start()).status).toBe(409);
      expect((await callWeb(alice, 'POST /games/{gameId}/recordings/{recordingId}/jobs', { path: recPath(), body: { where: 'moon' } })).status).toBe(400);
    });

    it('says so when the server has no cloud processing', async () => {
      delete process.env.BATCH_JOBS;
      try {
        const r = await start();
        expect(r.status).toBe(503);
        expect(r.body.error).toBe('cloud_unavailable');
      } finally {
        process.env.BATCH_JOBS = JSON.stringify(BATCH_JOBS);
      }
    });
  });

  it('starts the prepare job, one per recording, and the game shows it', async () => {
    const r = await start();
    expect(r.status).toBe(201);
    expect(r.body).toMatchObject({
      schemaVersion: 1,
      gameId,
      recordingId,
      where: 'cloud',
      status: 'queued',
      phase: 'prepare',
      checks: { pitch: 'open', kits: 'open' },
      progress: null,
      error: null,
      stale: false,
      finishedAt: null,
    });
    const jobId = r.body.jobId;
    expect(submits()).toHaveLength(1);
    expect(submits()[0]).toMatchObject({
      jobName: `osb-prepare-${jobId}`,
      jobQueue: 'gpu-queue',
      jobDefinition: 'prepare-def',
      containerOverrides: { command: ['prepare'] },
    });
    const env = Object.fromEntries(submits()[0]!.containerOverrides!.environment!.map((e) => [e.name, e.value]));
    expect(env).toEqual({
      OSB_COMMAND: 'prepare',
      OSB_JOB_ID: jobId,
      OSB_FOOTAGE_PREFIX: `accounts/${alice}/games/${gameId}/recordings/${recordingId}/`,
      OSB_OUTPUT_PREFIX: outputs(jobId),
      OSB_WORK_PREFIX: work(jobId),
    });

    expect((await start()).status).toBe(409);
    expect((await start(alice, 'local')).status).toBe(409);
    expect(submits()).toHaveLength(1);

    const game = await callWeb(alice, 'GET /games/{gameId}', { path: { gameId } });
    expect(game.body.recordings[0].job).toMatchObject({ jobId, status: 'queued' });
    expect((await get(jobId)).body).toMatchObject({ jobId, status: 'queued' });
    expect((await get(jobId, randomUUID())).status).toBe(404);
    expect((await get(randomUUID())).status).toBe(404);
  });

  it('fails the job and frees the recording when Batch refuses it', async () => {
    refuseNext = new Error('queue is disabled');
    const r = await start();
    expect(r.status).toBe(503);
    const game = await callWeb(alice, 'GET /games/{gameId}', { path: { gameId } });
    expect(game.body.recordings[0].job).toMatchObject({ status: 'failed', error: { code: 'machine_failed' } });
    expect((await start()).status).toBe(201);
  });

  it('goes from prepare through both checks to the video', async () => {
    const jobId = (await start()).body.jobId as string;
    const questions = () =>
      callWeb(alice, 'GET /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/questions', { path: jobPath(jobId) });
    expect((await questions()).status).toBe(409);

    await event('prepare', jobId, 'RUNNING');
    expect((await get(jobId)).body.status).toBe('preparing');
    // The container may report how far it is.
    await put(`${outputs(jobId)}questions/questions.json`, JSON.stringify(QUESTIONS(jobId)));
    await event('prepare', jobId, 'SUCCEEDED');
    expect((await get(jobId)).body).toMatchObject({ status: 'needs_answers', phase: 'prepare' });
    expect(emails()).toEqual(['Check the pitch for your game']);
    const sent = sesMock.commandCalls(SendEmailCommand)[0]!.args[0].input;
    expect(sent.Destination).toEqual({ ToAddresses: ['alice@example.com'] });
    expect(sent.Content!.Simple!.Body!.Text!.Data).toContain(`https://osb.example.com/game?id=${gameId}`);
    // Batch delivers an event more than once.
    await event('prepare', jobId, 'SUCCEEDED');
    expect(emails()).toHaveLength(1);

    const q = await questions();
    expect(q.status).toBe(200);
    expect(q.body.checks).toEqual({ pitch: 'open', kits: 'open' });
    expect(q.body.questions.pitch.imageUrl.startsWith(`https://${CDN}/${outputs(jobId)}questions/pitch.jpg?`)).toBe(true);
    expect(q.body.questions.kits.groups[0].people[0].imageUrl).toContain('/questions/kits/g0/p0.jpg?');
    // The engine's files can't point outside their folder.
    expect(q.body.questions.kits.groups[0].people[1].imageUrl).toBeNull();

    const a1 = await answer(jobId, approve);
    expect(a1.status).toBe(200);
    expect(a1.body).toMatchObject({ status: 'needs_answers', checks: { pitch: 'answered', kits: 'open' } });
    expect((await answer(jobId, approve)).status).toBe(409);
    expect(submits()).toHaveLength(1);

    const a2 = await answer(jobId, kitsOk);
    expect(a2.body).toMatchObject({ status: 'queued', phase: 'run', checks: { pitch: 'answered', kits: 'answered' } });
    expect(submits()).toHaveLength(2);
    expect(submits()[1]).toMatchObject({ jobName: `osb-run-${jobId}`, jobDefinition: 'run-def', containerOverrides: { command: ['run'] } });
    const saved = JSON.parse(
      await (await s3.send(new GetObjectCommand({ Bucket: config.bucket, Key: `${outputs(jobId)}answers.json` }))).Body!.transformToString(),
    );
    expect(saved).toMatchObject({
      schemaVersion: 1,
      jobId,
      pitch: { round: 1, approved: true, answeredAt: expect.any(String) },
      kits: { round: 1, wrong: [{ groupId: 'g0', personId: 'p1' }], structure: { kind: 'ok' } },
    });
    expect((await answer(jobId, kitsOk)).status).toBe(409);

    // The prepare job's late events no longer speak for the record.
    await event('prepare', jobId, 'FAILED', 0);
    expect((await get(jobId)).body.status).toBe('queued');

    await event('run', jobId, 'RUNNING');
    expect((await get(jobId)).body.status).toBe('running');
    const video = () =>
      callWeb(alice, 'POST /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/downloads', { path: jobPath(jobId) });
    expect((await video()).status).toBe(409);
    await put(`${outputs(jobId)}game.mp4`, randomBytes(321));
    await event('run', jobId, 'SUCCEEDED');
    const done = (await get(jobId)).body;
    expect(done).toMatchObject({ status: 'done', error: null, finishedAt: expect.any(String) });
    expect(emails()).toEqual(['Check the pitch for your game', 'Your game video is ready']);

    const v = await video();
    expect(v.status).toBe(200);
    expect(v.body.video.bytes).toBe(321);
    expect(v.body.video.url.startsWith(`https://${CDN}/${outputs(jobId)}game.mp4?`)).toBe(true);

    // Machine time per Batch job, for cost.
    const item = (await ddb.send(new GetCommand({ TableName: config.table, Key: keys.job(jobId) }))).Item!;
    expect(item.compute).toEqual({ 'batch-0': 90, 'batch-1': 90 });

    // A finished job doesn't block the next one.
    expect((await start()).status).toBe(201);
  });

  describe('answers', () => {
    it('a marked pitch is refitted and asked again', async () => {
      const jobId = await prepared();
      const marked = {
        check: 'pitch',
        round: 1,
        approved: false,
        keypoints: [{ id: 'near_left_corner', x: 120, y: 410 }, { id: 'near_right_corner', skipped: true }],
      };
      const r = await answer(jobId, marked);
      expect(r.body).toMatchObject({ status: 'refitting', checks: { pitch: 'open', kits: 'open' } });
      expect(submits()[1]).toMatchObject({ jobName: `osb-refit-${jobId}`, jobQueue: 'cpu-queue', jobDefinition: 'refit-def' });
      expect(submits()[1]!.containerOverrides!.environment).toContainEqual({ name: 'OSB_CHECK', value: 'pitch' });
      expect((await answer(jobId, approve)).status).toBe(409);

      await put(`${outputs(jobId)}questions/questions.json`, JSON.stringify(QUESTIONS(jobId, 2)));
      await event('refit', jobId, 'SUCCEEDED');
      expect((await get(jobId)).body).toMatchObject({ status: 'needs_answers', checks: { pitch: 'open', kits: 'open' } });
      // One email per game, not per refit.
      expect(emails()).toHaveLength(1);

      // An answer to the old drawing is refused; the new one is taken.
      expect((await answer(jobId, approve)).status).toBe(409);
      expect((await answer(jobId, { ...approve, round: 2 })).body.checks.pitch).toBe('answered');
    });

    it('a kit group to split is refitted; merging is not', async () => {
      const jobId = await prepared();
      const split = await answer(jobId, { check: 'kits', round: 1, wrong: [], structure: { kind: 'split', group: 'g1' } });
      expect(split.body).toMatchObject({ status: 'refitting', checks: { kits: 'open' } });
      expect(submits()[1]!.containerOverrides!.environment).toContainEqual({ name: 'OSB_CHECK', value: 'kits' });
      await put(`${outputs(jobId)}questions/questions.json`, JSON.stringify(QUESTIONS(jobId, 1, false)));
      await event('refit', jobId, 'SUCCEEDED');
      const again = await answer(jobId, { check: 'kits', round: 1, wrong: [], structure: { kind: 'split', group: 'g1' } });
      expect(again.status).toBe(400);
      const merged = await answer(jobId, { check: 'kits', round: 1, wrong: [], structure: { kind: 'merge', groups: ['g0', 'g1'] } });
      expect(merged.body).toMatchObject({ status: 'needs_answers', checks: { kits: 'answered' } });
      expect(submits()).toHaveLength(2);
    });

    it('fails a refit that wrote no new questions', async () => {
      const jobId = await prepared();
      // Batch's clock, a second later than the questions the prepare wrote.
      await new Promise((r) => setTimeout(r, 1100));
      await answer(jobId, { check: 'pitch', round: 1, approved: false, keypoints: [] });
      await event('refit', jobId, 'SUCCEEDED');
      expect((await get(jobId)).body).toMatchObject({ status: 'failed', error: { code: 'engine_no_result' } });
    });

    it('refuses answers that do not fit the questions', async () => {
      const jobId = await prepared();
      const bad = [
        { check: 'ball' },
        { check: 'pitch', round: 1 },
        { check: 'pitch', round: 1, approved: false },
        { check: 'pitch', round: 1, approved: false, keypoints: [{ id: 'centre_spot', x: 1, y: 1 }] },
        { check: 'pitch', round: 1, approved: false, keypoints: [{ id: 'near_left_corner', x: 1, y: 1 }, { id: 'near_left_corner', skipped: true }] },
        { check: 'pitch', round: 1, approved: true, paint: 'yellow' },
        { check: 'kits', round: 1, wrong: [{ groupId: 'g1', personId: 'p1' }], structure: { kind: 'ok' } },
        { check: 'kits', round: 1, wrong: [], structure: { kind: 'merge', groups: ['g0'] } },
        { check: 'kits', round: 1, wrong: [], structure: { kind: 'split', group: 'g9' } },
        { check: 'kits', round: 1, wrong: [], structure: { kind: 'ok' }, extra: 1 },
      ];
      for (const b of bad) expect((await answer(jobId, b)).status, JSON.stringify(b)).toBe(400);
      expect((await get(jobId)).body).toMatchObject({ status: 'needs_answers', checks: { pitch: 'open', kits: 'open' } });
      expect(submits()).toHaveLength(1);
    });

    it('goes back to waiting when the run cannot be started', async () => {
      const jobId = await prepared();
      await answer(jobId, approve);
      refuseNext = new Error('throttled');
      expect((await answer(jobId, kitsOk)).status).toBe(503);
      expect((await get(jobId)).body).toMatchObject({ status: 'needs_answers', phase: 'prepare', checks: { pitch: 'answered', kits: 'open' } });
      expect((await answer(jobId, kitsOk)).body.status).toBe('queued');
    });
  });

  describe('when the machine or the engine fails', () => {
    it('keeps the error the engine left on the record', async () => {
      const jobId = (await start()).body.jobId as string;
      await event('prepare', jobId, 'RUNNING');
      // What the container writes: progress and, before it exits, its error.
      await ddb.send(
        new UpdateCommand({
          TableName: config.table,
          Key: keys.job(jobId),
          UpdateExpression: 'SET progress = :p, #e = :e',
          ExpressionAttributeNames: { '#e': 'error' },
          ExpressionAttributeValues: {
            ':p': { stage: 'sync', fraction: 0.2 },
            ':e': { code: 'footage_corrupt', message: 'Segment 3 of the main phone could not be read.' },
          },
        }),
      );
      expect((await get(jobId)).body.progress).toEqual({ stage: 'sync', fraction: 0.2 });
      await event('prepare', jobId, 'FAILED', 0, { statusReason: 'Essential container in task exited', container: { exitCode: 3 } });
      expect((await get(jobId)).body).toMatchObject({ status: 'failed', error: { code: 'footage_corrupt' } });
      expect(emails()).toEqual(['Your game could not be processed']);
      expect(sesMock.commandCalls(SendEmailCommand)[0]!.args[0].input.Content!.Simple!.Body!.Text!.Data).toContain('Segment 3');
      await event('prepare', jobId, 'FAILED', 0);
      expect(emails()).toHaveLength(1);
      expect((await start()).status).toBe(201);
    });

    it('names a timeout, a lost machine, and an engine that left nothing', async () => {
      const cases: [object, string][] = [
        [{ statusReason: 'Job attempt duration exceeded timeout' }, 'timed_out'],
        [{ statusReason: 'Host EC2 (instance i-0abc) terminated.' }, 'machine_failed'],
        [{ statusReason: 'CAPACITY:INSUFFICIENT_INSTANCE_CAPACITY - Service cannot fulfill the capacity requested for instance type [g5.xlarge]' }, 'no_machine'],
        [{ statusReason: 'Essential container in task exited', container: { exitCode: 1 } }, 'engine_failed'],
      ];
      for (const [extra, code] of cases) {
        const jobId = (await start()).body.jobId as string;
        await event('prepare', jobId, 'FAILED', batchIds.length - 1, extra);
        expect((await get(jobId)).body, code).toMatchObject({ status: 'failed', error: { code } });
      }
      const jobId = (await start()).body.jobId as string;
      await event('prepare', jobId, 'SUCCEEDED');
      expect((await get(jobId)).body).toMatchObject({ status: 'failed', error: { code: 'engine_no_result' } });
    });

    it('ignores Batch jobs that are not ours', async () => {
      await batchEvent({ detail: { jobName: 'someone-elses-job', jobId: 'b', status: 'FAILED' } } as any);
      await batchEvent({ detail: { jobName: `osb-run-${randomUUID()}`, jobId: 'b', status: 'FAILED' } } as any);
    });
  });

  describe('cancelling', () => {
    const cancel = (jobId: string, acct = alice) =>
      callWeb(acct, 'DELETE /games/{gameId}/recordings/{recordingId}/jobs/{jobId}', { path: jobPath(jobId) });

    it('stops the Batch job, and its end changes nothing', async () => {
      const jobId = (await start()).body.jobId as string;
      expect((await cancel(jobId, randomUUID())).status).toBe(404);
      expect((await cancel(jobId)).status).toBe(204);
      expect(batchMock.commandCalls(TerminateJobCommand)[0]!.args[0].input).toMatchObject({ jobId: 'batch-0' });
      expect((await get(jobId)).body).toMatchObject({ status: 'cancelled', finishedAt: expect.any(String) });
      await event('prepare', jobId, 'FAILED', 0);
      expect((await get(jobId)).body.status).toBe('cancelled');
      expect(emails()).toHaveLength(0);
      expect((await cancel(jobId)).status).toBe(409);
      expect((await start()).status).toBe(201);
    });

    it('a second ready (a late Secondary) cancels a job in flight and marks a finished one stale', async () => {
      // One finished job on Main's footage alone.
      const first = await prepared();
      await answer(first, approve);
      await answer(first, kitsOk);
      await put(`${outputs(first)}game.mp4`);
      await event('run', first, 'SUCCEEDED');
      // ...and a second in flight.
      const second = (await start()).body.jobId as string;

      const secondary = await linkPhone(alice, 'Pixel 8');
      const secFiles = [randomBytes(30)];
      expect(
        (
          await callDevice(secondary.token, 'PUT /games/{gameId}/recordings/{recordingId}/report', {
            path: recPath(),
            body: deviceEntry(secondary, 'secondary', secFiles),
          })
        ).status,
      ).toBe(200);
      // Still uploading: no new job yet, and the one in flight carries on.
      expect((await get(second)).body.status).toBe('queued');
      await new Promise((r) => setTimeout(r, 5));
      expect((await uploadFile(secondary, gameId, recordingId, 0, secFiles[0]!)).status).toBe(200);

      expect((await get(second)).body).toMatchObject({ status: 'cancelled', error: { code: 'superseded' } });
      expect(batchMock.commandCalls(TerminateJobCommand).map((c) => c.args[0].input.jobId)).toEqual(['batch-2']);
      expect((await get(first)).body).toMatchObject({ status: 'done', stale: true });
      const again = await start();
      expect(again.status).toBe(201);
      expect(again.body.stale).toBe(false);
    });
  });

  describe('deleting', () => {
    const jobItems = async () => (await queryPrefix<{ sk: string }>(alice, 'JOB#')).map((i) => i.sk);

    it('a recording takes its jobs, their Batch job and everything they wrote', async () => {
      const jobId = await prepared();
      await put(`${work(jobId)}chunks/piece_00.mp4`);
      await put(`outputs/${alice}/games/${gameId}/recordings/${randomUUID()}/jobs/${randomUUID()}/game.mp4`);
      expect(await jobItems()).toHaveLength(1);

      const r = await callWeb(alice, 'DELETE /games/{gameId}/recordings/{recordingId}', { path: recPath() });
      expect(r.status).toBe(204);
      expect(batchMock.commandCalls(TerminateJobCommand)).toHaveLength(1);
      expect(await keysUnder(outputs(jobId))).toEqual([]);
      expect(await keysUnder(work(jobId))).toEqual([]);
      expect(await jobItems()).toEqual([]);
      expect((await ddb.send(new GetCommand({ TableName: config.table, Key: keys.job(jobId) }))).Item).toBeUndefined();
      // Another recording's output is left alone.
      expect(await keysUnder(`outputs/${alice}/`)).toHaveLength(1);
      // The Batch job's end finds no record.
      await event('prepare', jobId, 'FAILED', 0);
      expect((await get(jobId)).status).toBe(404);
    });

    it('a game and an account do the same', async () => {
      const jobId = await prepared();
      expect((await callWeb(alice, 'DELETE /games/{gameId}', { path: { gameId } })).status).toBe(204);
      expect(await keysUnder(`outputs/${alice}/`)).toEqual([]);
      expect(await jobItems()).toEqual([]);
      expect((await ddb.send(new GetCommand({ TableName: config.table, Key: keys.job(jobId) }))).Item).toBeUndefined();

      gameId = randomUUID();
      recordingId = randomUUID();
      await makeReady();
      const other = await prepared();
      expect((await callWeb(alice, 'DELETE /me')).status).toBe(204);
      expect(await keysUnder(`outputs/${alice}/`)).toEqual([]);
      expect((await ddb.send(new GetCommand({ TableName: config.table, Key: keys.job(other) }))).Item).toBeUndefined();
      expect((await ddb.send(new GetCommand({ TableName: config.table, Key: keys.settings(alice) }))).Item).toBeUndefined();
    });
  });

  describe('a job on the user’s own computer', () => {
    const report = (jobId: string, body: unknown) =>
      callWeb(alice, 'PUT /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/status', { path: jobPath(jobId), body });

    it('is written by the app, start to finish, with no Batch job', async () => {
      const r = await start(alice, 'local');
      expect(r.body).toMatchObject({ where: 'local', status: 'preparing', phase: 'prepare' });
      const jobId = r.body.jobId as string;
      expect((await start()).status).toBe(409);

      expect((await report(jobId, { status: 'needs_answers' })).body.status).toBe('needs_answers');
      const running = await report(jobId, {
        status: 'running',
        engineVersion: 'osb-engine 0.2.0 (abc1234)',
        progress: { stage: 'ball', fraction: 0.4, etaSeconds: 9000 },
      });
      expect(running.body).toMatchObject({
        status: 'running',
        phase: 'run',
        engineVersion: 'osb-engine 0.2.0 (abc1234)',
        progress: { stage: 'ball', fraction: 0.4, etaSeconds: 9000 },
      });
      expect((await report(jobId, { status: 'queued' })).status).toBe(400);
      expect((await report(jobId, { status: 'running', progress: { stage: 'ball', fraction: 2 } })).status).toBe(400);
      expect((await answer(jobId, approve)).status).toBe(403);

      expect((await report(jobId, { status: 'done' })).body).toMatchObject({ status: 'done', finishedAt: expect.any(String) });
      expect((await report(jobId, { status: 'running' })).status).toBe(409);
      expect(submits()).toHaveLength(0);
      expect(emails()).toHaveLength(0);
    });

    it('records a failure with the engine’s code, and a cloud job refuses these reports', async () => {
      const jobId = (await start(alice, 'local')).body.jobId as string;
      const failed = await report(jobId, { status: 'failed', error: { code: 'not_enough_disk', message: 'Needs 100 GB free.' } });
      expect(failed.body).toMatchObject({ status: 'failed', error: { code: 'not_enough_disk', message: 'Needs 100 GB free.' } });
      const cloud = (await start()).body.jobId as string;
      expect((await report(cloud, { status: 'done' })).status).toBe(403);
    });
  });
});
