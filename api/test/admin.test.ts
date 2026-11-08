// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { randomBytes, randomUUID } from 'node:crypto';
import {
  AdminCreateUserCommand,
  CognitoIdentityProviderClient,
  CreateUserPoolCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import { ListObjectsV2Command, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { handler as admin } from '../src/handlers/admin.js';
import { groupsOf } from '../src/lib/admin.js';
import { config, segmentKey } from '../src/lib/store.js';
import { callDevice, callWeb, linkPhone, manifest, resetAws, uploadFile } from './helpers.js';

const idp = new CognitoIdentityProviderClient({});

const s3 = new S3Client({ forcePathStyle: true });

async function callAdmin(groups: string | undefined, routeKey = 'GET /admin/accounts', path?: Record<string, string>) {
  const claims: Record<string, string> = { sub: randomUUID() };
  if (groups !== undefined) claims['cognito:groups'] = groups;
  const r = await admin({
    routeKey,
    pathParameters: path,
    requestContext: { authorizer: { jwt: { claims, scopes: [] } } },
  } as any);
  return { status: r.statusCode, body: r.body ? JSON.parse(r.body) : undefined };
}

describe('groupsOf', () => {
  it('reads the groups claim as API Gateway passes it, or as an array', () => {
    expect(groupsOf({ 'cognito:groups': '[admins]' })).toEqual(['admins']);
    expect(groupsOf({ 'cognito:groups': '[coaches admins]' })).toEqual(['coaches', 'admins']);
    expect(groupsOf({ 'cognito:groups': ['admins'] })).toEqual(['admins']);
    expect(groupsOf({})).toEqual([]);
  });
});

describe('GET /admin/accounts', () => {
  let alice: string;
  let bob: string;

  beforeEach(async () => {
    await resetAws();
    const pool = await idp.send(new CreateUserPoolCommand({ PoolName: `osb-${randomUUID()}` }));
    process.env.USER_POOL_ID = pool.UserPool!.Id!;
    alice = randomUUID();
    bob = randomUUID();
    for (const u of [alice, bob]) {
      await idp.send(
        new AdminCreateUserCommand({
          UserPoolId: config.userPoolId,
          Username: u,
          UserAttributes: [{ Name: 'email', Value: `${u}@example.com` }],
        }),
      );
    }
  });

  it('is refused to anyone not in the admins group', async () => {
    expect((await callAdmin(undefined)).status).toBe(403);
    expect((await callAdmin('[coaches]')).status).toBe(403);
  });

  it('GET /me says whether the caller is an admin', async () => {
    expect((await callWeb(alice, 'GET /me')).body.admin).toBe(false);
  });

  it('reports each account’s phones, games, recordings and storage', async () => {
    const phone = await linkPhone(alice, 'Pixel 9');
    const gameId = randomUUID();
    const recordingId = randomUUID();
    const files = [randomBytes(250), randomBytes(120)];
    expect(
      (await callDevice(phone.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
        path: { gameId, recordingId },
        body: manifest(gameId, recordingId, phone, files),
      })).status,
    ).toBe(200);
    expect((await uploadFile(phone, gameId, recordingId, 0, files[0]!)).status).toBe(200);
    // A second recording, still waiting for its manifest.
    expect((await uploadFile(phone, randomUUID(), randomUUID(), 0, files[1]!)).status).toBe(200);

    const r = await callAdmin('[admins]');
    expect(r.status).toBe(200);
    const a = r.body.accounts.find((x: any) => x.accountId === alice);
    const b = r.body.accounts.find((x: any) => x.accountId === bob);
    expect(a).toMatchObject({
      email: `${alice}@example.com`,
      status: 'active',
      games: 2,
      recordings: { total: 2, uploading: 1, waiting_for_manifest: 1, ready: 0 },
      objectCount: 2,
      storageBytes: 370,
    });
    expect(a.devices).toEqual([expect.objectContaining({ deviceId: phone.deviceId, model: 'Pixel 9' })]);
    expect(a.lastUploadAt).toEqual(expect.any(String));
    expect(b).toMatchObject({ games: 0, storageBytes: 0, objectCount: 0, devices: [], lastUploadAt: null });
    // Biggest first.
    expect(r.body.accounts[0].accountId).toBe(alice);
    expect(r.body.totals).toMatchObject({ accounts: 2, deletedAccounts: 0, devices: 1, games: 2, recordings: 2 });
    expect(r.body.totals.storageBytes).toBe(a.storageBytes);
  });

  it('counts deleted accounts but leaves out the ones with nothing left', async () => {
    await linkPhone(bob, 'iPhone 17');
    expect((await callWeb(bob, 'DELETE /me')).status).toBe(204);
    const r = await callAdmin('[admins]');
    expect(r.body.accounts.map((x: any) => x.accountId)).toEqual([alice]);
    expect(r.body.totals).toMatchObject({ accounts: 1, deletedAccounts: 1 });
  });
});

describe('admin deletes', () => {
  let alice: string;

  beforeEach(async () => {
    await resetAws();
    const pool = await idp.send(new CreateUserPoolCommand({ PoolName: `osb-${randomUUID()}` }));
    process.env.USER_POOL_ID = pool.UserPool!.Id!;
    alice = randomUUID();
    await idp.send(
      new AdminCreateUserCommand({
        UserPoolId: config.userPoolId,
        Username: alice,
        UserAttributes: [{ Name: 'email', Value: 'alice@example.com' }],
      }),
    );
  });

  const keysUnder = async (prefix: string) =>
    ((await s3.send(new ListObjectsV2Command({ Bucket: config.bucket, Prefix: prefix }))).Contents ?? []).map((o) => o.Key);

  /** Two recordings in one game, plus a second game. */
  async function fill() {
    const phone = await linkPhone(alice);
    const gameId = randomUUID();
    const [rec1, rec2] = [randomUUID(), randomUUID()];
    const otherGame = randomUUID();
    expect((await uploadFile(phone, gameId, rec1, 0, randomBytes(100))).status).toBe(200);
    expect((await uploadFile(phone, gameId, rec2, 0, randomBytes(40))).status).toBe(200);
    expect((await uploadFile(phone, otherGame, randomUUID(), 0, randomBytes(10))).status).toBe(200);
    return { phone, gameId, rec1, rec2, otherGame };
  }

  it('lists an account’s games and recordings with their footage', async () => {
    const { gameId, rec1, rec2 } = await fill();
    const r = await callAdmin('[admins]', 'GET /admin/accounts/{accountId}/games', { accountId: alice });
    expect(r.status).toBe(200);
    expect(r.body.email).toBe('alice@example.com');
    expect(r.body.games).toHaveLength(2);
    const g = r.body.games.find((x: any) => x.gameId === gameId);
    expect(g).toMatchObject({ inTable: true, storageBytes: 140, objectCount: 2 });
    expect(g.recordings.map((x: any) => [x.recordingId, x.storageBytes, x.status]).sort()).toEqual(
      [[rec1, 100, 'waiting_for_manifest'], [rec2, 40, 'waiting_for_manifest']].sort(),
    );
  });

  it('deletes one recording, leaving the rest, and logs who did it', async () => {
    const { phone, gameId, rec1, rec2 } = await fill();
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    const path = { accountId: alice, gameId, recordingId: rec1 };
    const d = await callAdmin('[admins]', 'DELETE /admin/accounts/{accountId}/games/{gameId}/recordings/{recordingId}', path);
    expect(d.status).toBe(204);
    expect(log.mock.calls.map((c) => JSON.parse(c[0]))).toEqual([
      expect.objectContaining({ audit: true, action: 'delete_recording', accountId: alice, gameId, recordingId: rec1 }),
    ]);
    log.mockRestore();
    expect(await keysUnder(`accounts/${alice}/games/${gameId}/recordings/${rec1}/`)).toEqual([]);
    expect(await keysUnder(`accounts/${alice}/games/${gameId}/recordings/${rec2}/`)).toHaveLength(1);
    // The owner sees it gone, and the phone is refused if it tries again.
    const game = await callWeb(alice, 'GET /games/{gameId}', { path: { gameId } });
    expect(game.body.recordings.map((x: any) => x.recordingId)).toEqual([rec2]);
    expect((await uploadFile(phone, gameId, rec1, 0, randomBytes(100))).status).toBe(410);
  });

  it('deletes a whole game', async () => {
    const { gameId, otherGame } = await fill();
    const d = await callAdmin('[admins]', 'DELETE /admin/accounts/{accountId}/games/{gameId}', { accountId: alice, gameId });
    expect(d.status).toBe(204);
    expect(await keysUnder(`accounts/${alice}/games/${gameId}/`)).toEqual([]);
    expect((await callWeb(alice, 'GET /games')).body.games.map((g: any) => g.gameId)).toEqual([otherGame]);
  });

  it('deletes footage the table has no record of, and 404s when there is nothing', async () => {
    const gameId = randomUUID();
    const recordingId = randomUUID();
    const dev = randomUUID();
    const key = segmentKey(alice, gameId, recordingId, dev, `${dev}_000.mp4`);
    await s3.send(new PutObjectCommand({ Bucket: config.bucket, Key: key, Body: randomBytes(20) }));
    const list = await callAdmin('[admins]', 'GET /admin/accounts/{accountId}/games', { accountId: alice });
    expect(list.body.games).toEqual([
      expect.objectContaining({ gameId, inTable: false, storageBytes: 20, recordings: [expect.objectContaining({ recordingId, status: null })] }),
    ]);
    const path = { accountId: alice, gameId, recordingId };
    const route = 'DELETE /admin/accounts/{accountId}/games/{gameId}/recordings/{recordingId}';
    expect((await callAdmin('[admins]', route, path)).status).toBe(204);
    expect(await keysUnder(`accounts/${alice}/`)).toEqual([]);
    expect((await callAdmin('[admins]', route, { ...path, recordingId: randomUUID() })).status).toBe(404);
  });

  it('is refused to non-admins', async () => {
    const { gameId } = await fill();
    expect((await callAdmin('[coaches]', 'GET /admin/accounts/{accountId}/games', { accountId: alice })).status).toBe(403);
    const d = await callAdmin(undefined, 'DELETE /admin/accounts/{accountId}/games/{gameId}', { accountId: alice, gameId });
    expect(d.status).toBe(403);
    expect(await keysUnder(`accounts/${alice}/games/${gameId}/`)).toHaveLength(2);
  });
});
