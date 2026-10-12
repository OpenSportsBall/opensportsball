// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { randomUUID } from 'node:crypto';
import { PutCommand } from '@aws-sdk/lib-dynamodb';
import { beforeEach, describe, expect, it } from 'vitest';
import { ANONYMOUS, handler as authorizer } from '../src/handlers/authorizer.js';
import { config, ddb, keys } from '../src/lib/store.js';
import { callDevice, callWeb, linkPhone, resetAws } from './helpers.js';

const authorize = (token: string) => authorizer({ headers: { authorization: `Bearer ${token}` } } as any);
/** Whether the token identifies a phone (unknown tokens pass with no identity). */
const valid = async (token: string) => (await authorize(token)).context.deviceId !== '';

describe('linking phones', () => {
  beforeEach(resetAws);
  const alice = randomUUID();
  const bob = randomUUID();

  it('creates a single-use code that links a phone', async () => {
    const code = await callWeb(alice, 'POST /link-codes');
    expect(code.status).toBe(201);
    expect(code.body.code).toMatch(/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/);
    expect(code.body.linkUri).toBe(
      `opensportsball://link?v=1&api=${encodeURIComponent('https://abc123.execute-api.us-east-1.amazonaws.com')}&code=${code.body.code}`,
    );

    const deviceId = randomUUID();
    const link = (id = deviceId) =>
      callDevice(null, 'POST /devices/link', { body: { code: code.body.code, deviceId: id, platform: 'android', model: 'Pixel 9' } });
    const first = await link();
    expect(first.status).toBe(200);
    expect(first.body.accountId).toBe(alice);
    expect(first.body.deviceToken).toMatch(/^osbd_[A-Za-z0-9_-]{43}$/);

    expect((await link(randomUUID())).status).toBe(410); // used

    const auth = await authorize(first.body.deviceToken);
    expect(auth).toEqual({ isAuthorized: true, context: { accountId: alice, deviceId } });

    const devices = await callWeb(alice, 'GET /devices');
    expect(devices.body.devices).toMatchObject([{ deviceId, platform: 'android', model: 'Pixel 9' }]);
    expect((await callWeb(bob, 'GET /devices')).body.devices).toEqual([]);
  });

  it('a linked phone creates codes for its own account (Main linking Secondary)', async () => {
    const main = await linkPhone(alice);
    const code = await callDevice(main.token, 'POST /devices/link-codes');
    expect(code.status).toBe(201);
    expect(code.body.linkUri).toContain(`code=${code.body.code}`);

    const deviceId = randomUUID();
    const r = await callDevice(null, 'POST /devices/link', {
      body: { code: code.body.code, deviceId, platform: 'android', model: 'Pixel 9 Pro' },
    });
    expect(r.body.accountId).toBe(alice);
    expect((await callWeb(alice, 'GET /devices')).body.devices).toHaveLength(2);

    expect((await callDevice(`osbd_${'A'.repeat(43)}`, 'POST /devices/link-codes')).status).toBe(401);
  });

  it('rejects unknown and expired codes', async () => {
    const body = (code: string) => ({ body: { code, deviceId: randomUUID(), platform: 'ios', model: 'iPhone' } });
    expect((await callDevice(null, 'POST /devices/link', body('ABCDEFGH'))).status).toBe(404);

    await ddb.send(
      new PutCommand({
        TableName: config.table,
        Item: { ...keys.linkCode('HJKMNPQR'), accountId: alice, expiresAtMs: Date.now() - 1000 },
      }),
    );
    expect((await callDevice(null, 'POST /devices/link', body('HJKMNPQR'))).status).toBe(410);
    expect((await callDevice(null, 'POST /devices/link', body('bad'))).status).toBe(400);
  });

  it('will not move a phone to a second account', async () => {
    const phone = await linkPhone(alice);
    const code = await callWeb(bob, 'POST /link-codes');
    const r = await callDevice(null, 'POST /devices/link', {
      body: { code: code.body.code, deviceId: phone.deviceId, platform: 'android', model: 'Pixel 9' },
    });
    expect(r.status).toBe(409);
    expect(await valid(phone.token)).toBe(true);
  });

  it('re-linking to the same account replaces the old token', async () => {
    const phone = await linkPhone(alice);
    const code = await callWeb(alice, 'POST /link-codes');
    const again = await callDevice(null, 'POST /devices/link', {
      body: { code: code.body.code, deviceId: phone.deviceId, platform: 'android', model: 'Pixel 9' },
    });
    expect(again.status).toBe(200);
    expect(await valid(phone.token)).toBe(false);
    expect(await valid(again.body.deviceToken)).toBe(true);
    expect((await callWeb(alice, 'GET /devices')).body.devices).toHaveLength(1);
  });

  it('unlinking revokes the token immediately, and only the owner can unlink', async () => {
    const phone = await linkPhone(alice);
    expect((await callWeb(bob, 'DELETE /devices/{deviceId}', { path: { deviceId: phone.deviceId } })).status).toBe(404);
    expect((await callWeb(alice, 'DELETE /devices/{deviceId}', { path: { deviceId: phone.deviceId } })).status).toBe(204);
    expect(await valid(phone.token)).toBe(false);
    expect((await callWeb(alice, 'GET /devices')).body.devices).toEqual([]);

    // Free to join another account now.
    const code = await callWeb(bob, 'POST /link-codes');
    const r = await callDevice(null, 'POST /devices/link', {
      body: { code: code.body.code, deviceId: phone.deviceId, platform: 'android', model: 'Pixel 9' },
    });
    expect(r.status).toBe(200);
  });

  it('malformed and unknown tokens get no identity, and phone routes answer 401', async () => {
    expect(await authorize('nope')).toEqual(ANONYMOUS);
    expect(await authorize(`osbd_${'A'.repeat(43)}`)).toEqual(ANONYMOUS);
    expect(await authorizer({ headers: {} } as any)).toEqual(ANONYMOUS);
    const r = await callDevice(`osbd_${'A'.repeat(43)}`, 'POST /uploads', { body: {} });
    expect(r).toEqual({ status: 401, body: { error: 'unauthorized', message: 'Device token required.' } });
  });
});
