// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import { randomBytes, randomUUID } from 'node:crypto';
import { GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { beforeEach, describe, expect, it } from 'vitest';
import { handler as ingest } from '../src/handlers/ingest.js';
import { config, manifestKey, segmentKey } from '../src/lib/store.js';
import {
  callDevice,
  callWeb,
  fileName,
  linkPhone,
  manifest,
  readyEvents,
  resetAws,
  sha,
  uploadFile,
  type Phone,
} from './helpers.js';

const s3 = new S3Client({ forcePathStyle: true });

describe('recording upload', () => {
  let acct: string;
  let main: Phone;
  let secondary: Phone;
  let gameId: string;
  let recordingId: string;
  // 250 bytes = 3 parts of 100; 100 = exactly 1 part; 1 byte; 120 = 2 parts.
  const mainFiles = [randomBytes(250), randomBytes(100)];
  const secFiles = [randomBytes(1), randomBytes(120)];
  const path = () => ({ gameId, recordingId });

  beforeEach(async () => {
    await resetAws();
    acct = randomUUID();
    main = await linkPhone(acct, 'Pixel 9');
    secondary = await linkPhone(acct, 'Galaxy S25');
    gameId = randomUUID();
    recordingId = randomUUID();
  });

  const putManifest = (m: unknown, phone = main) =>
    callDevice(phone.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', { path: path(), body: m });

  it('goes from manifest to ready and hands off to processing once', async () => {
    const m = manifest(gameId, recordingId, main, mainFiles, secondary, secFiles);
    const first = await putManifest(m);
    expect(first.status).toBe(200);
    expect(first.body.status).toBe('uploading');
    expect(first.body.missing).toHaveLength(4);

    const stored = await s3.send(new GetObjectCommand({ Bucket: config.bucket, Key: manifestKey(acct, gameId, recordingId) }));
    expect(JSON.parse(await stored.Body!.transformToString()).sessionId).toBe(recordingId);

    for (const [i, f] of mainFiles.entries()) expect((await uploadFile(main, gameId, recordingId, i, f)).status).toBe(200);
    expect((await uploadFile(secondary, gameId, recordingId, 0, secFiles[0]!)).status).toBe(200);
    expect(await readyEvents()).toEqual([]);

    const game = await callWeb(acct, 'GET /games/{gameId}', { path: { gameId } });
    expect(game.body.recordings[0]).toMatchObject({ status: 'uploading', hasManifest: true });
    expect(game.body.recordings[0].devices).toEqual([
      expect.objectContaining({ role: 'main', model: 'Pixel 9', expectedSegments: 2, uploadedSegments: 2, expectedBytes: 350, uploadedBytes: 350 }),
      expect.objectContaining({ role: 'secondary', expectedSegments: 2, uploadedSegments: 1, expectedBytes: 121, uploadedBytes: 1 }),
    ]);

    expect((await uploadFile(secondary, gameId, recordingId, 1, secFiles[1]!)).status).toBe(200);
    const events = await readyEvents();
    expect(events).toEqual([
      {
        accountId: acct,
        gameId,
        recordingId,
        bucket: config.bucket,
        prefix: `accounts/${acct}/games/${gameId}/recordings/${recordingId}/`,
        manifestKey: manifestKey(acct, gameId, recordingId),
      },
    ]);

    // Files are byte-for-byte what the phones sent.
    const obj = await s3.send(
      new GetObjectCommand({ Bucket: config.bucket, Key: segmentKey(acct, gameId, recordingId, main.deviceId, fileName(main, 0)) }),
    );
    expect(sha(Buffer.from(await obj.Body!.transformToByteArray()))).toBe(sha(mainFiles[0]!));

    // Re-sending the same manifest, re-uploading, and the S3 event all leave it ready without a second event.
    expect((await putManifest(m)).body).toEqual({ status: 'ready', missing: [] });
    expect((await uploadFile(main, gameId, recordingId, 0, mainFiles[0]!)).body).toEqual({ alreadyUploaded: true });
    await ingest(s3Event(segmentKey(acct, gameId, recordingId, main.deviceId, fileName(main, 0)), 250));
    expect(await readyEvents()).toEqual([]);

    const games = await callWeb(acct, 'GET /games');
    expect(games.body.games).toEqual([{ gameId, createdAt: expect.any(String), recordingCount: 1, status: 'ready' }]);

    // A different manifest can't replace a finished recording.
    const changed = manifest(gameId, recordingId, main, [mainFiles[0]!], secondary, secFiles);
    expect((await putManifest(changed)).status).toBe(409);
  });

  it('resumes an interrupted upload from the parts S3 already has', async () => {
    const data = randomBytes(250);
    const partial = await uploadFile(main, gameId, recordingId, 0, data, 2);
    expect(partial.body).toEqual({ stopped: true });

    const resumed = await callDevice(main.token, 'POST /uploads', {
      body: { gameId, recordingId, fileName: fileName(main, 0), bytes: 250, sha256: sha(data) },
    });
    expect(resumed.body.completedParts.map((p: any) => p.partNumber)).toEqual([1, 2]);
    expect(resumed.body.parts.map((p: any) => p.partNumber)).toEqual([3]);

    expect((await uploadFile(main, gameId, recordingId, 0, data)).status).toBe(200);
    const obj = await s3.send(
      new GetObjectCommand({ Bucket: config.bucket, Key: segmentKey(acct, gameId, recordingId, main.deviceId, fileName(main, 0)) }),
    );
    expect(sha(Buffer.from(await obj.Body!.transformToByteArray()))).toBe(sha(data));
  });

  it('starts over if the file changed since the upload began', async () => {
    const before = randomBytes(250);
    await uploadFile(main, gameId, recordingId, 0, before, 1);
    const after = randomBytes(220);
    const r = await callDevice(main.token, 'POST /uploads', {
      body: { gameId, recordingId, fileName: fileName(main, 0), bytes: 220, sha256: sha(after) },
    });
    expect(r.body.completedParts).toEqual([]);
    expect(r.body.parts).toHaveLength(3);
  });

  it('segments uploaded before the manifest count once it arrives', async () => {
    const solo = manifest(gameId, recordingId, main, mainFiles);
    for (const [i, f] of mainFiles.entries()) await uploadFile(main, gameId, recordingId, i, f);

    const waiting = await callWeb(acct, 'GET /games/{gameId}', { path: { gameId } });
    expect(waiting.body.recordings[0]).toMatchObject({ status: 'waiting_for_manifest', hasManifest: false });
    expect(waiting.body.recordings[0].devices).toEqual([
      { deviceId: main.deviceId, role: null, model: null, expectedSegments: null, uploadedSegments: 2, expectedBytes: null, uploadedBytes: 350 },
    ]);

    expect((await putManifest(solo)).body).toEqual({ status: 'ready', missing: [] });
    expect(await readyEvents()).toHaveLength(1);
  });

  it('a file of the wrong size does not count toward ready', async () => {
    await putManifest(manifest(gameId, recordingId, main, [mainFiles[0]!]));
    const key = segmentKey(acct, gameId, recordingId, main.deviceId, fileName(main, 0));
    await s3.send(new PutObjectCommand({ Bucket: config.bucket, Key: key, Body: randomBytes(10) }));
    await ingest(s3Event(key, 10));
    const game = await callWeb(acct, 'GET /games/{gameId}', { path: { gameId } });
    expect(game.body.recordings[0]).toMatchObject({ status: 'uploading' });
    expect(game.body.recordings[0].devices[0].uploadedSegments).toBe(0);
  });

  describe('manifest rules', () => {
    it('only the main phone can upload it', async () => {
      const r = await putManifest(manifest(gameId, recordingId, main, mainFiles, secondary, secFiles), secondary);
      expect(r.status).toBe(403);
    });

    it('every phone in it must be linked to the account', async () => {
      const stranger = await linkPhone(randomUUID());
      const r = await putManifest(manifest(gameId, recordingId, main, mainFiles, stranger, secFiles));
      expect(r.status).toBe(403);
      expect(r.body.message).toContain(stranger.deviceId);
    });

    it('ids must match the URL', async () => {
      const r = await putManifest(manifest(randomUUID(), recordingId, main, mainFiles));
      expect(r.status).toBe(400);
    });

    it('schema violations come back with details', async () => {
      const m: any = manifest(gameId, recordingId, main, mainFiles, secondary, secFiles);
      delete m.clockSync;
      m.devices[0].video.codec = 'vp9';
      const r = await putManifest(m);
      expect(r.status).toBe(400);
      expect(r.body.error).toBe('invalid_manifest');
      expect(r.body.details.length).toBeGreaterThanOrEqual(2);
    });

    it('segment paths must belong to their device', async () => {
      const m: any = manifest(gameId, recordingId, main, mainFiles, secondary, secFiles);
      m.devices[1].segments[0].objectKey = `${secondary.deviceId}/${fileName(main, 0)}`;
      expect((await putManifest(m)).status).toBe(400);
    });

    it('rejects a body that is not JSON', async () => {
      const r = await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
        path: path(),
        rawBody: '{nope',
      });
      expect(r.status).toBe(400);
    });
  });

  describe('upload rules', () => {
    it('a phone can only upload its own files', async () => {
      const r = await callDevice(main.token, 'POST /uploads', {
        body: { gameId, recordingId, fileName: fileName(secondary, 0), bytes: 10, sha256: sha(Buffer.from('x')) },
      });
      expect(r.status).toBe(400);
    });

    it('uploads land under the caller\'s own account', async () => {
      const other = randomUUID();
      const theirs = await linkPhone(other);
      await uploadFile(theirs, gameId, recordingId, 0, randomBytes(5));
      expect((await callWeb(acct, 'GET /games')).body.games).toEqual([]);
      expect((await callWeb(other, 'GET /games')).body.games).toHaveLength(1);
    });

    it('completing needs every part, in order', async () => {
      const data = randomBytes(250);
      const start = await callDevice(main.token, 'POST /uploads', {
        body: { gameId, recordingId, fileName: fileName(main, 0), bytes: 250, sha256: sha(data) },
      });
      const r = await callDevice(main.token, 'POST /uploads/complete', {
        body: { gameId, recordingId, fileName: fileName(main, 0), uploadId: start.body.uploadId, parts: [{ partNumber: 1, etag: '"x"' }] },
      });
      expect(r.status).toBe(400);
      const wrongId = await callDevice(main.token, 'POST /uploads/complete', {
        body: { gameId, recordingId, fileName: fileName(main, 0), uploadId: 'nope', parts: [] },
      });
      expect(wrongId.status).toBe(404);
    });

    it('an unlinked phone can no longer upload', async () => {
      await callWeb(acct, 'DELETE /devices/{deviceId}', { path: { deviceId: main.deviceId } });
      const r = await callDevice(main.token, 'POST /uploads', {
        body: { gameId, recordingId, fileName: fileName(main, 0), bytes: 10, sha256: sha(Buffer.from('x')) },
      });
      expect(r.status).toBe(401);
    });
  });

  it('other accounts cannot see a game', async () => {
    await putManifest(manifest(gameId, recordingId, main, mainFiles));
    expect((await callWeb(randomUUID(), 'GET /games/{gameId}', { path: { gameId } })).status).toBe(404);
  });
});

function s3Event(key: string, size: number) {
  return {
    Records: [{ s3: { bucket: { name: config.bucket }, object: { key: encodeURIComponent(key).replace(/%2F/g, '/'), size } } }],
  } as any;
}
