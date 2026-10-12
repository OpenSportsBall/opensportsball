// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { randomBytes, randomUUID } from 'node:crypto';
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { beforeEach, describe, expect, it } from 'vitest';
import { handler as authorizer } from '../src/handlers/authorizer.js';
import { config, ddb, keys, manifestKey } from '../src/lib/store.js';
import { hashToken } from '../src/lib/tokens.js';
import {
  callDevice,
  callWeb,
  deviceEntry,
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
const authorize = (token: string) => authorizer({ headers: { authorization: `Bearer ${token}` } } as any);

describe('recording grants', () => {
  let alice: string;
  let main: Phone;
  let gameId: string;
  let recordingId: string;
  const mainFiles = [randomBytes(250)];
  const secFiles = [randomBytes(1), randomBytes(120)];

  beforeEach(async () => {
    await resetAws();
    alice = randomUUID();
    main = await linkPhone(alice, 'Pixel 9');
    gameId = randomUUID();
    recordingId = randomUUID();
  });

  const grant = (deviceId: string, game = gameId, by = main) =>
    callDevice(by.token, 'POST /games/{gameId}/grants', { path: { gameId: game }, body: { deviceId } });

  /** The Secondary as it uploads for Main: its own deviceId, the grant token. */
  async function granted(deviceId = randomUUID(), model = 'Galaxy S25'): Promise<Phone> {
    const r = await grant(deviceId);
    expect(r.status).toBe(201);
    return { deviceId, token: r.body.grantToken, model };
  }

  const path = () => ({ gameId, recordingId });
  const putManifest = (m: unknown) =>
    callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', { path: path(), body: m });
  const putReport = (phone: Phone, body: unknown, p = path()) =>
    callDevice(phone.token, 'PUT /games/{gameId}/recordings/{recordingId}/report', { path: p, body });

  async function recordTogether(secondary: Phone) {
    expect((await putManifest(manifest(gameId, recordingId, main, mainFiles, secondary))).status).toBe(200);
    for (const [i, f] of mainFiles.entries()) await uploadFile(main, gameId, recordingId, i, f);
    for (const [i, f] of secFiles.entries()) {
      expect((await uploadFile(secondary, gameId, recordingId, i, f)).status).toBe(200);
    }
    return putReport(secondary, deviceEntry(secondary, 'secondary', secFiles));
  }

  it('Main creates a grant for a phone and game', async () => {
    const deviceId = randomUUID();
    const r = await grant(deviceId);
    expect(r.status).toBe(201);
    expect(r.body).toEqual({
      grantToken: expect.stringMatching(/^osbg_[A-Za-z0-9_-]{43}$/),
      apiUrl: 'https://abc123.execute-api.us-east-1.amazonaws.com',
      accountId: alice,
      gameId,
      deviceId,
      expiresAt: expect.any(String),
    });
    const days = (Date.parse(r.body.expiresAt) - Date.now()) / 86_400_000;
    expect(days).toBeGreaterThan(13.9);
    expect(days).toBeLessThanOrEqual(14);
    expect(await authorize(r.body.grantToken)).toEqual({
      isAuthorized: true,
      context: { accountId: alice, deviceId, grantGameId: gameId },
    });
  });

  it('a phone on no account uploads its part into Main\'s account', async () => {
    const secondary = await granted();
    const r = await recordTogether(secondary);
    expect(r.body).toEqual({ status: 'ready', missing: [], awaitingReports: [] });
    expect(await readyEvents()).toHaveLength(1);

    const stored = await s3.send(new GetObjectCommand({ Bucket: config.bucket, Key: manifestKey(alice, gameId, recordingId) }));
    const merged = JSON.parse(await stored.Body!.transformToString());
    expect(merged.devices[1].segments).toEqual(deviceEntry(secondary, 'secondary', secFiles).segments);

    // It does not show up as one of Alice's phones.
    expect((await callWeb(alice, 'GET /devices')).body.devices).toHaveLength(1);
  });

  it('a phone on another account stays there, and records for Main with a grant', async () => {
    const bob = randomUUID();
    const bobsPhone = await linkPhone(bob, 'Galaxy S25');
    const secondary = await granted(bobsPhone.deviceId, bobsPhone.model);

    expect((await recordTogether(secondary)).body.status).toBe('ready');
    expect((await callWeb(alice, 'GET /games')).body.games).toHaveLength(1);
    expect((await callWeb(bob, 'GET /games')).body.games).toEqual([]);

    // Still Bob's phone, and still able to be Main for Bob.
    expect((await callWeb(bob, 'GET /devices')).body.devices).toMatchObject([{ deviceId: bobsPhone.deviceId }]);
    const ownGame = randomUUID();
    expect((await uploadFile(bobsPhone, ownGame, randomUUID(), 0, randomBytes(5))).status).toBe(200);
    expect((await callWeb(bob, 'GET /games')).body.games).toMatchObject([{ gameId: ownGame }]);
  });

  it('a phone can hold grants from several accounts at once', async () => {
    const carol = randomUUID();
    const carolsMain = await linkPhone(carol, 'iPhone');
    const deviceId = randomUUID();
    const forAlice = await granted(deviceId);
    const r = await grant(deviceId, gameId, carolsMain);
    const forCarol: Phone = { ...forAlice, token: r.body.grantToken };

    await uploadFile(forAlice, gameId, recordingId, 0, randomBytes(3));
    await uploadFile(forCarol, gameId, recordingId, 0, randomBytes(4));
    expect((await callWeb(alice, 'GET /games')).body.games).toHaveLength(1);
    expect((await callWeb(carol, 'GET /games')).body.games).toHaveLength(1);
  });

  it('asking again replaces the grant', async () => {
    const deviceId = randomUUID();
    const first = await granted(deviceId);
    const second = await granted(deviceId);
    expect((await authorize(first.token)).context.deviceId).toBe('');
    expect((await authorize(second.token)).context.deviceId).toBe(deviceId);
  });

  it('an expired grant gets no identity', async () => {
    const secondary = await granted();
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.token(hashToken(secondary.token)),
        UpdateExpression: 'SET expiresAtMs = :past',
        ExpressionAttributeValues: { ':past': Date.now() - 1000 },
      }),
    );
    const r = await uploadFile(secondary, gameId, recordingId, 0, secFiles[0]!);
    expect(r.status).toBe(401);
  });

  describe('what a grant can do', () => {
    it('only its own game', async () => {
      const secondary = await granted();
      const other = randomUUID();
      expect((await uploadFile(secondary, other, recordingId, 0, secFiles[0]!)).status).toBe(403);
      const r = await putReport(secondary, deviceEntry(secondary, 'secondary', secFiles), { gameId: other, recordingId });
      expect(r.status).toBe(403);
      expect((await callWeb(alice, 'GET /games')).body.games).toEqual([]);
    });

    it('only its own files', async () => {
      const secondary = await granted();
      const r = await callDevice(secondary.token, 'POST /uploads', {
        body: { gameId, recordingId, fileName: fileName(main, 0), bytes: 10, sha256: sha(Buffer.from('x')) },
      });
      expect(r.status).toBe(400);
    });

    it('no manifest, no more grants, no unlinking', async () => {
      const secondary = await granted();
      const m = await callDevice(secondary.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
        path: path(),
        body: manifest(gameId, recordingId, secondary, secFiles),
      });
      expect(m.status).toBe(403);
      expect((await grant(randomUUID(), gameId, secondary)).status).toBe(403);
      expect((await callDevice(secondary.token, 'POST /devices/unlink')).status).toBe(403);
    });
  });

  describe('creating grants', () => {
    it('needs a device token', async () => {
      const r = await callDevice(`osbd_${'A'.repeat(43)}`, 'POST /games/{gameId}/grants', {
        path: { gameId },
        body: { deviceId: randomUUID() },
      });
      expect(r.status).toBe(401);
    });

    it('not for the caller itself, and only with valid ids', async () => {
      expect((await grant(main.deviceId)).status).toBe(400);
      expect((await grant('nope')).status).toBe(400);
      expect((await grant(randomUUID(), 'nope')).status).toBe(400);
    });

    it('Main\'s manifest may name a phone only if it is linked here or has a grant', async () => {
      const stranger: Phone = { deviceId: randomUUID(), token: '', model: 'Galaxy S25' };
      const without = await putManifest(manifest(gameId, recordingId, main, mainFiles, stranger));
      expect(without.status).toBe(403);
      // A grant for another game does not count.
      await grant(stranger.deviceId, randomUUID());
      expect((await putManifest(manifest(gameId, recordingId, main, mainFiles, stranger))).status).toBe(403);
      await grant(stranger.deviceId);
      expect((await putManifest(manifest(gameId, recordingId, main, mainFiles, stranger))).status).toBe(200);
    });
  });
});
