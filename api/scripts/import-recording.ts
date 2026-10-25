// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Imports a recording copied off the phones (a folder with the phone's
 * manifest.json and <deviceId>/<deviceId>_NNN.mp4 segments) into an
 * account on the live stack, as if the phones had uploaded it: each
 * segment goes to its usual key, is recorded with the API's own
 * recordObject, and the API's checkReady writes the merged manifest.json,
 * marks the recording ready and publishes RecordingReady.
 *
 *   npx esbuild scripts/import-recording.ts --bundle --platform=node --format=esm \
 *       --packages=external --outfile=/tmp/import-recording.mjs
 *   AWS_PROFILE=<profile> AWS_REGION=us-west-2 node /tmp/import-recording.mjs \
 *       --account <acct> --dir <recording folder> [--yes]
 *
 * Without --yes it checks the manifest (the API's schema check) and every
 * file's size and sha256, and prints what it would write. Files already in
 * the bucket at the right size are not uploaded again, so a stopped import
 * can be rerun. The phones' link or grant to the account is not checked:
 * this is an admin import. scripts/delete-recording.ts undoes it.
 * Uploads use the AWS CLI (aws s3 cp: multipart, retries). Table and
 * bucket come from infra/cdk-outputs.json unless TABLE_NAME or BUCKET_NAME
 * are set. Run from api/.
 */

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { HeadObjectCommand } from '@aws-sdk/client-s3';
import { UpdateCommand } from '@aws-sdk/lib-dynamodb';

const { values: args } = parseArgs({
  options: {
    account: { type: 'string' },
    dir: { type: 'string' },
    yes: { type: 'boolean', default: false },
  },
});
if (!args.account || !args.dir) {
  console.error('usage: --account <acct> --dir <recording folder> [--yes]');
  process.exit(2);
}

// Relative to the working directory (api/), not this file: it runs bundled.
if (!process.env.TABLE_NAME || !process.env.BUCKET_NAME || !process.env.AWS_REGION) {
  const outputs = JSON.parse(readFileSync(join(process.cwd(), '../infra/cdk-outputs.json'), 'utf8'))
    .OpenSportsBall as Record<string, string>;
  process.env.TABLE_NAME ??= outputs.TableName!;
  process.env.BUCKET_NAME ??= outputs.FootageBucket!;
  process.env.AWS_REGION ??= outputs.UserPoolId!.split('_')[0];
}

// After the environment is set: store.ts reads it.
const { parseManifest } = await import('../src/lib/manifest.js');
const { checkReady, ensureRecording, getRecording, recordObject } = await import('../src/lib/recordings.js');
const { config, ddb, keys, s3, segmentKey } = await import('../src/lib/store.js');

const acct = args.account;
const raw = JSON.parse(readFileSync(join(args.dir, 'manifest.json'), 'utf8')) as Record<string, unknown>;
const main = (raw.devices as { role: string; deviceId: string }[]).find((d) => d.role === 'main');
const gameId = raw.gameId as string;
const recordingId = raw.sessionId as string;
const manifest = parseManifest(raw, { gameId, recordingId, callerDeviceId: main?.deviceId ?? '' });

async function sha256(path: string) {
  const h = createHash('sha256');
  for await (const chunk of createReadStream(path)) h.update(chunk as Buffer);
  return h.digest('hex');
}

async function headSize(key: string) {
  try {
    return (await s3.send(new HeadObjectCommand({ Bucket: config.bucket, Key: key }))).ContentLength;
  } catch (e) {
    if ((e as { name?: string }).name === 'NotFound') return undefined;
    throw e;
  }
}

type File = { deviceId: string; fileName: string; path: string; bytes: number; sha256: string; key: string };
const files: File[] = [];
for (const d of manifest.devices) {
  for (const s of d.segments ?? []) {
    const fileName = s.objectKey.split('/').pop()!;
    files.push({
      deviceId: d.deviceId,
      fileName,
      path: join(args.dir, s.objectKey),
      bytes: s.bytes,
      sha256: s.sha256,
      key: segmentKey(acct, gameId, recordingId, d.deviceId, fileName),
    });
  }
}

const total = files.reduce((n, f) => n + f.bytes, 0);
console.log(`account ${acct}  game ${gameId}  recording ${recordingId}`);
console.log(`${manifest.devices.map((d) => `${d.role} ${d.deviceId}`).join(', ')}`);
console.log(`${files.length} segments, ${(total / 1e9).toFixed(1)} GB -> s3://${config.bucket}/${files[0]?.key.replace(/[^/]+\/[^/]+$/, '')}`);

const existing = await getRecording(acct, gameId, recordingId);
const sha = createHash('sha256').update(JSON.stringify(raw)).digest('hex');
if (existing?.status === 'ready' && existing.manifestSha256 !== sha) {
  console.error('This recording is already ready in that account with a different manifest; not importing.');
  process.exit(1);
}
console.log(`table: recording ${existing ? `exists (${existing.status})` : 'new'}`);

console.log('checking local files (size and sha256)...');
for (const f of files) {
  if (!existsSync(f.path) || statSync(f.path).size !== f.bytes) throw new Error(`${f.path}: missing or not ${f.bytes} bytes`);
  if ((await sha256(f.path)) !== f.sha256) throw new Error(`${f.path}: sha256 differs from the manifest`);
}
const there = await Promise.all(files.map(async (f) => (await headSize(f.key)) === f.bytes));
console.log(`all ${files.length} match the manifest; ${there.filter(Boolean).length} already in the bucket`);

if (!args.yes) {
  console.log('\nWould write: GAME and REC items (manifest, status uploading), upload the missing segments,');
  console.log('an OBJ item per segment, then (via checkReady) manifest.json, status ready and RecordingReady.');
  console.log('Dry run: nothing written. Add --yes to import.');
  process.exit(0);
}

// As PUT .../manifest does, without its link/grant check.
await ensureRecording(acct, gameId, recordingId);
const alreadyReady = existing?.status === 'ready';
await ddb.send(
  new UpdateCommand({
    TableName: config.table,
    Key: keys.recording(acct, gameId, recordingId),
    UpdateExpression: alreadyReady
      ? 'SET manifest = :m, manifestSha256 = :sha'
      : 'SET manifest = :m, manifestSha256 = :sha, #s = :uploading',
    ExpressionAttributeNames: alreadyReady ? undefined : { '#s': 'status' },
    ExpressionAttributeValues: { ':m': manifest, ':sha': sha, ...(alreadyReady ? {} : { ':uploading': 'uploading' }) },
  }),
);

let sent = 0;
for (const [i, f] of files.entries()) {
  if (!there[i]) {
    const t0 = Date.now();
    const r = spawnSync(
      'aws',
      ['s3', 'cp', f.path, `s3://${config.bucket}/${f.key}`, '--only-show-errors',
        '--content-type', 'video/mp4', '--metadata', `sha256=${f.sha256}`],
      { stdio: 'inherit' },
    );
    if (r.status !== 0) throw new Error(`aws s3 cp failed for ${f.fileName}`);
    if ((await headSize(f.key)) !== f.bytes) throw new Error(`${f.fileName}: wrong size in the bucket after upload`);
    sent += f.bytes;
    const s = (Date.now() - t0) / 1000;
    console.log(`${i + 1}/${files.length} ${f.fileName} ${(f.bytes / 1e9).toFixed(2)} GB in ${s.toFixed(0)} s` +
      ` (${((f.bytes * 8) / 1e6 / s).toFixed(0)} Mbit/s)`);
  }
  const res = await recordObject({ accountId: acct, gameId, recordingId, deviceId: f.deviceId, fileName: f.fileName, bytes: f.bytes });
  if (there[i]) console.log(`${i + 1}/${files.length} ${f.fileName} already there; ${res.status}`);
}

const final = await checkReady(acct, gameId, recordingId);
console.log(`uploaded ${(sent / 1e9).toFixed(1)} GB; recording ${final.status}` +
  (final.missing.length ? `, missing ${final.missing.map((m) => m.fileName).join(' ')}` : ''));
