// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { randomBytes, randomUUID } from 'node:crypto';
import {
  AdminCreateUserCommand,
  CognitoIdentityProviderClient,
  CreateUserPoolCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import { beforeEach, describe, expect, it } from 'vitest';
import { handler as admin } from '../src/handlers/admin.js';
import { groupsOf } from '../src/lib/admin.js';
import { config } from '../src/lib/store.js';
import { callDevice, callWeb, linkPhone, manifest, resetAws, uploadFile } from './helpers.js';

const idp = new CognitoIdentityProviderClient({});

async function callAdmin(groups: string | undefined, routeKey = 'GET /admin/accounts') {
  const claims: Record<string, string> = { sub: randomUUID() };
  if (groups !== undefined) claims['cognito:groups'] = groups;
  const r = await admin({ routeKey, requestContext: { authorizer: { jwt: { claims, scopes: [] } } } } as any);
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
