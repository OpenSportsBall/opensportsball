// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { randomBytes, randomUUID } from 'node:crypto';
import {
  AdminCreateUserCommand,
  AdminGetUserCommand,
  CognitoIdentityProviderClient,
  CreateUserPoolCommand,
  UserNotFoundException,
} from '@aws-sdk/client-cognito-identity-provider';
import { ListMultipartUploadsCommand, ListObjectsV2Command, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { GetCommand, QueryCommand } from '@aws-sdk/lib-dynamodb';
import { beforeEach, describe, expect, it } from 'vitest';
import { handler as ingest } from '../src/handlers/ingest.js';
import { config, ddb, keys, segmentKey } from '../src/lib/store.js';
import { hashToken } from '../src/lib/tokens.js';
import {
  callDevice,
  callWeb,
  deviceEntry,
  fileName,
  linkPhone,
  manifest,
  resetAws,
  uploadFile,
  type Phone,
} from './helpers.js';

const s3 = new S3Client({ forcePathStyle: true });
const idp = new CognitoIdentityProviderClient({});

const objectKeys = async (prefix: string) =>
  ((await s3.send(new ListObjectsV2Command({ Bucket: config.bucket, Prefix: prefix }))).Contents ?? []).map((o) => o.Key);
const openUploads = async (prefix: string) =>
  (await s3.send(new ListMultipartUploadsCommand({ Bucket: config.bucket, Prefix: prefix }))).Uploads ?? [];
async function sortKeys(acct: string) {
  const r = await ddb.send(
    new QueryCommand({
      TableName: config.table,
      KeyConditionExpression: 'pk = :pk',
      ExpressionAttributeValues: { ':pk': `ACCOUNT#${acct}` },
    }),
  );
  return (r.Items ?? []).map((i) => i.sk as string);
}
const item = async (key: { pk: string; sk: string }) =>
  (await ddb.send(new GetCommand({ TableName: config.table, Key: key }))).Item;
async function userExists(username: string) {
  try {
    await idp.send(new AdminGetUserCommand({ UserPoolId: config.userPoolId, Username: username }));
    return true;
  } catch (e) {
    if (e instanceof UserNotFoundException) return false;
    throw e;
  }
}

describe('deleting an account', () => {
  let alice: string;
  let bob: string;
  let main: Phone;
  let secondary: Phone;
  let gameId: string;
  let recordingId: string;
  const files = [randomBytes(250), randomBytes(120)];
  const secFiles = [randomBytes(30)];

  beforeEach(async () => {
    await resetAws();
    const pool = await idp.send(new CreateUserPoolCommand({ PoolName: `osb-${randomUUID()}` }));
    process.env.USER_POOL_ID = pool.UserPool!.Id!;
    alice = randomUUID();
    bob = randomUUID();
    for (const u of [alice, bob]) {
      await idp.send(new AdminCreateUserCommand({ UserPoolId: config.userPoolId, Username: u }));
    }
    main = await linkPhone(alice, 'Pixel 9');
    gameId = randomUUID();
    recordingId = randomUUID();
    secondary = { deviceId: randomUUID(), token: '', model: 'Galaxy S25' };
  });

  /** Alice's account with: a game recorded by Main and a Secondary on a
   *  grant, one unfinished upload, a website ticket, and Main's unbound
   *  tickets. Bob has a game too. */
  async function fill() {
    const sec = await callDevice(main.token, 'POST /games/{gameId}/grants', {
      path: { gameId },
      body: { deviceId: secondary.deviceId },
    });
    secondary = { ...secondary, token: sec.body.grantToken };
    const m = manifest(gameId, recordingId, main, files, secondary);
    expect(
      (await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
        path: { gameId, recordingId },
        body: m,
      })).status,
    ).toBe(200);
    expect((await uploadFile(main, gameId, recordingId, 0, files[0]!)).status).toBe(200);
    expect((await uploadFile(main, gameId, recordingId, 1, files[1]!, 1)).status).toBe(0);
    expect((await uploadFile(secondary, gameId, recordingId, 0, secFiles[0]!)).status).toBe(200);
    expect(
      (await callDevice(secondary.token, 'PUT /games/{gameId}/recordings/{recordingId}/report', {
        path: { gameId, recordingId },
        body: deviceEntry(secondary, 'secondary', secFiles),
      })).status,
    ).toBe(200);
    const webTicket = await callWeb(alice, 'POST /games/{gameId}/grant-tickets', { path: { gameId } });
    expect(webTicket.status).toBe(201);
    const tickets = await callDevice(main.token, 'POST /grant-tickets', { body: { count: 2 } });
    expect(tickets.status).toBe(201);

    const bobPhone = await linkPhone(bob, 'iPhone 17');
    expect((await uploadFile(bobPhone, randomUUID(), randomUUID(), 0, files[0]!)).status).toBe(200);
    return { webTicket: webTicket.body.ticket as string, tickets: tickets.body.tickets.map((t: any) => t.ticket) as string[], bobPhone };
  }

  it('removes footage, phones, tokens, items and the sign-in, and leaves only a CLOSED marker', async () => {
    const { webTicket, tickets, bobPhone } = await fill();
    expect(await objectKeys(`accounts/${alice}/`)).toHaveLength(2);
    expect(await openUploads(`accounts/${alice}/`)).toHaveLength(1);

    expect((await callWeb(alice, 'DELETE /me')).status).toBe(204);

    expect(await objectKeys(`accounts/${alice}/`)).toEqual([]);
    expect(await openUploads(`accounts/${alice}/`)).toEqual([]);
    expect(await sortKeys(alice)).toEqual(['CLOSED']);
    expect(await item(keys.owner(main.deviceId))).toBeUndefined();
    for (const t of [main.token, secondary.token, webTicket, ...tickets]) {
      expect(await item(keys.token(hashToken(t)))).toBeUndefined();
    }
    expect(await userExists(alice)).toBe(false);

    // The phone hears it was signed out; tickets no longer work.
    expect((await callDevice(main.token, 'POST /uploads', { body: {} })).status).toBe(401);
    expect((await uploadFile(secondary, gameId, recordingId, 0, secFiles[0]!)).status).toBe(401);
    const redeem = await callDevice(null, 'POST /grants/redeem', {
      body: { ticket: webTicket, gameId, deviceId: randomUUID() },
    });
    expect(redeem.status).toBe(404);

    // Bob is untouched.
    expect(await objectKeys(`accounts/${bob}/`)).toHaveLength(1);
    expect(await item(keys.owner(bobPhone.deviceId))).toBeDefined();
    expect(await userExists(bob)).toBe(true);
    expect((await callWeb(bob, 'GET /games')).body.games).toHaveLength(1);

    // Again (say, after a timeout) is fine.
    expect((await callWeb(alice, 'DELETE /me')).status).toBe(204);
  });

  it('a link code made before the delete cannot bring the account back', async () => {
    const code = await callWeb(alice, 'POST /link-codes');
    expect((await callWeb(alice, 'DELETE /me')).status).toBe(204);
    const linked = await callDevice(null, 'POST /devices/link', {
      body: { code: code.body.code, deviceId: randomUUID(), platform: 'ios', model: 'iPhone 17' },
    });
    expect(linked.status).toBe(410);
    expect(await sortKeys(alice)).toEqual(['CLOSED']);
  });

  it('a file that lands after the delete is removed, not recorded', async () => {
    expect((await callWeb(alice, 'DELETE /me')).status).toBe(204);
    const key = segmentKey(alice, gameId, recordingId, main.deviceId, fileName(main, 0));
    await s3.send(new PutObjectCommand({ Bucket: config.bucket, Key: key, Body: files[0]! }));
    await ingest({
      Records: [
        { s3: { bucket: { name: config.bucket }, object: { key: encodeURIComponent(key).replace(/%2F/g, '/'), size: files[0]!.length } } },
      ],
    } as any);
    expect(await objectKeys(`accounts/${alice}/`)).toEqual([]);
    expect(await sortKeys(alice)).toEqual(['CLOSED']);
  });

  it('works when the sign-in is already gone', async () => {
    const ghost = randomUUID();
    await linkPhone(ghost);
    expect((await callWeb(ghost, 'DELETE /me')).status).toBe(204);
    expect(await sortKeys(ghost)).toEqual(['CLOSED']);
  });
});
