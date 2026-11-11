// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

// A stand-in for the engine's container, so cloud processing can be
// deployed and tried end to end before the real engine exists. It keeps
// the container's side of the contract (docs/API.md, "The engine's
// container"): it reads the job from OSB_* variables, writes
// questions/questions.json or game.mp4 under the output prefix, reports
// progress on the job record, and exits 0 or non-zero. It reads no
// footage beyond checking the manifest is there.
//
//   node stub.mjs prepare | refit | run
//
// OSB_STUB_SECONDS  how long a command pretends to work (default 20)
// OSB_STUB_FAIL     fail with this error code instead of finishing

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { GetObjectCommand, HeadObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { DynamoDBDocumentClient, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { FIRST_FIT, FIRST_GROUPS, HEIGHT, WIDTH, keypoints, kitFiles, pitchLines, pitchSvg, splitGroup } from './scene.mjs';
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

const PITCH_TEXT =
  'This is the pitch with our best guess at its lines drawn on it. Do the drawn lines sit on the painted lines? ' +
  'If not, put each named point where it really is, or say you cannot see it.';
const KITS_TEXT =
  'Each group should be one kit. Mark anyone who is in the wrong group or is not a player in kit. ' +
  'Then say whether every kit has exactly one group, two groups are the same kit, or one group has two kits in it.';

async function writeQuestions({ pitchPoints, pitchRound, groups, kitsRound, canSplit }) {
  const kits = kitFiles(groups);
  await put(`${out}questions/pitch.svg`, pitchSvg());
  await Promise.all(kits.files.map((f) => put(`${out}questions/${f.path}`, f.body)));
  await put(
    `${out}questions/questions.json`,
    JSON.stringify({
      schemaVersion: 1,
      jobId,
      engineVersion: ENGINE_VERSION,
      pitch: {
        round: pitchRound,
        text: PITCH_TEXT,
        image: 'pitch.svg',
        width: WIDTH,
        height: HEIGHT,
        lines: pitchLines(pitchPoints),
        keypoints: keypoints(pitchPoints),
      },
      kits: { round: kitsRound, text: KITS_TEXT, canSplit, groups: kits.groups },
    }),
  );
  // What the next refit starts from.
  await put(`${work}state.json`, JSON.stringify({ pitchPoints, pitchRound, groups, kitsRound, canSplit }));
  say({ event: 'questions' });
}

async function prepare() {
  await requireManifest();
  await pretend(['sync', 'pitch', 'kits']);
  await writeQuestions({ pitchPoints: FIRST_FIT, pitchRound: 1, groups: FIRST_GROUPS, kitsRound: 1, canSplit: true });
}

async function refit() {
  const check = env('OSB_CHECK');
  const state = await getJson(`${work}state.json`);
  const answers = await getJson(`${out}answers.json`);
  if (!state || !answers?.[check]) throw new EngineError('nothing_to_refit', 'There is no answer to refit from.');
  await progress(check, 0.5);
  await sleep(Math.min(seconds, 5));
  if (check === 'pitch') {
    // The "refit": the lines go through the points the user placed.
    for (const k of answers.pitch.keypoints ?? []) {
      if (!k.skipped && state.pitchPoints[k.id]) state.pitchPoints[k.id] = [k.x, k.y];
    }
    state.pitchRound += 1;
  } else {
    const s = answers.kits.structure;
    if (s.kind === 'split') {
      state.groups = splitGroup(state.groups, s.group);
      state.canSplit = false;
    }
    state.kitsRound += 1;
  }
  await writeQuestions(state);
}

async function run() {
  await requireManifest();
  // Resume where a reclaimed Spot instance left off.
  const done = (await getJson(`${work}checkpoint.json`))?.fraction ?? 0;
  if (done > 0) console.log(`resuming from ${Math.round(done * 100)}%`);
  await pretend(['ball', 'roles', 'render', 'upload'], done, async (fraction) => {
    await put(`${work}checkpoint.json`, JSON.stringify({ fraction }));
  });
  await requireManifest();
  await put(`${out}game.mp4`, Buffer.from(VIDEO_BASE64, 'base64'));
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
