// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { GetCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { CognitoIdentityProviderClient, CreateUserPoolCommand } from '@aws-sdk/client-cognito-identity-provider';
import { PutParameterCommand, SSMClient } from '@aws-sdk/client-ssm';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { config, ddb, keys } from '../src/lib/store.js';
import { hashToken } from '../src/lib/tokens.js';
import { callDevice, callPublic, callWeb, fileName, linkPhone, manifest, resetAws, sha, uploadFile, type Phone } from './helpers.js';

const CDN = 'd222.cloudfront.net';
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const LINKS = '/games/{gameId}/recordings/{recordingId}/footage-links';

describe('footage links', () => {
  let alice: string;
  let main: Phone;
  let gameId: string;
  let recordingId: string;
  const files = [randomBytes(250), randomBytes(120)];
  const path = () => ({ gameId, recordingId });
  const create = (acct = alice, hours: unknown = 24) => callWeb(acct, `POST ${LINKS}`, { path: path(), body: { hours } });
  const list = async () => (await callWeb(alice, `GET ${LINKS}`, { path: path() })).body.links;
  const lookup = (token: unknown) => callPublic('POST /footage-links/lookup', { token });
  const tokenItem = async (token: string) =>
    (await ddb.send(new GetCommand({ TableName: config.table, Key: keys.token(hashToken(token)) }))).Item;

  beforeAll(async () => {
    process.env.FOOTAGE_CDN_DOMAIN = CDN;
    process.env.FOOTAGE_KEY_PAIR_ID = 'K2DOWNLOADS';
    process.env.FOOTAGE_SIGNING_KEY_PARAM = '/osb-test/footage-signing-key';
    await new SSMClient({}).send(
      new PutParameterCommand({
        Name: '/osb-test/footage-signing-key',
        Type: 'SecureString',
        Overwrite: true,
        Value: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
      }),
    );
  });

  beforeEach(async () => {
    await resetAws();
    // Deleting the account also deletes its sign-in (none here: that is fine).
    const pool = await new CognitoIdentityProviderClient({}).send(new CreateUserPoolCommand({ PoolName: `links-${randomUUID()}` }));
    process.env.USER_POOL_ID = pool.UserPool!.Id!;
    alice = randomUUID();
    main = await linkPhone(alice);
    gameId = randomUUID();
    recordingId = randomUUID();
    expect(
      (
        await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
          path: path(),
          body: manifest(gameId, recordingId, main, files),
        })
      ).status,
    ).toBe(200);
    for (const [i, f] of files.entries()) expect((await uploadFile(main, gameId, recordingId, i, f)).status).toBe(200);
  });

  it('gives anyone with the link every segment, with no sign-in, until the link expires', async () => {
    const before = Date.now();
    const made = await create();
    expect(made.status).toBe(201);
    expect(made.body.token).toMatch(/^osbf_[A-Za-z0-9_-]{43}$/);
    expect((Date.parse(made.body.expiresAt) - before) / 3_600_000).toBeCloseTo(24, 1);

    const r = await lookup(made.body.token);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('ready');
    expect(r.body.expiresAt).toBe(made.body.expiresAt);
    expect(r.body.devices).toEqual([{ deviceId: main.deviceId, role: 'main', model: expect.any(String) }]);
    expect(r.body.recordedAt).toEqual(expect.any(String));
    const prefix = `https://${CDN}/accounts/${alice}/games/${gameId}/recordings/${recordingId}/`;
    expect(r.body.files.map((f: any) => [f.fileName, f.bytes, f.sha256])).toEqual(
      files.map((f, i) => [fileName(main, i), f.length, sha(f)]),
    );
    for (const [i, f] of r.body.files.entries()) {
      expect(f.url.startsWith(`${prefix}${main.deviceId}/${fileName(main, i)}?`)).toBe(true);
    }
    expect(r.body.manifestUrl.startsWith(`${prefix}manifest.json?`)).toBe(true);
    // Signed for 12 hours at a time, however long the link lasts.
    expect((Date.parse(r.body.linksExpireAt) - before) / 3_600_000).toBeCloseTo(12, 1);
  });

  it('never signs a file link that outlasts the link itself', async () => {
    const { token } = (await create()).body;
    const soon = Date.now() + 3600_500;
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.token(hashToken(token)),
        UpdateExpression: 'SET expiresAtMs = :e',
        ExpressionAttributeValues: { ':e': soon },
      }),
    );
    const r = await lookup(token);
    expect(Date.parse(r.body.linksExpireAt)).toBe(Math.floor(soon / 1000) * 1000);
    expect(new URL(r.body.files[0].url).searchParams.get('Expires')).toBe(String(Math.floor(soon / 1000)));
  });

  it('is gone once it has expired, before DynamoDB removes it', async () => {
    const { token } = (await create()).body;
    for (const key of [keys.token(hashToken(token)), keys.footageLink(alice, gameId, recordingId, hashToken(token))]) {
      await ddb.send(
        new UpdateCommand({
          TableName: config.table,
          Key: key,
          UpdateExpression: 'SET expiresAtMs = :e',
          ExpressionAttributeValues: { ':e': Date.now() - 1 },
        }),
      );
    }
    expect((await lookup(token)).status).toBe(410);
    expect(await list()).toEqual([]);
  });

  it('lasts a day, three days or a week, and nothing else', async () => {
    for (const hours of [24, 72, 168]) {
      const before = Date.now();
      const r = await create(alice, hours);
      expect(r.status).toBe(201);
      expect((Date.parse(r.body.expiresAt) - before) / 3_600_000).toBeCloseTo(hours, 1);
    }
    for (const hours of [1, 169, 8760, '24', null]) expect((await create(alice, hours)).status).toBe(400);
  });

  it('stores only the hash, lists the links without their tokens, and stops one on request', async () => {
    const a = (await create()).body;
    const b = (await create(alice, 72)).body;
    expect(JSON.stringify(await tokenItem(a.token))).not.toContain(a.token);
    const links = await list();
    expect(links).toEqual([
      { linkId: a.linkId, createdAt: a.createdAt, expiresAt: a.expiresAt },
      { linkId: b.linkId, createdAt: b.createdAt, expiresAt: b.expiresAt },
    ]);

    const stop = (acct: string, linkId: string) =>
      callWeb(acct, `DELETE ${LINKS}/{linkId}`, { path: { ...path(), linkId } });
    expect((await stop(randomUUID(), a.linkId)).status).toBe(404); // not someone else's
    expect((await lookup(a.token)).status).toBe(200);
    expect((await stop(alice, a.linkId)).status).toBe(204);
    expect((await lookup(a.token)).status).toBe(404);
    expect((await stop(alice, a.linkId)).status).toBe(404);
    expect((await lookup(b.token)).status).toBe(200);
    expect((await list()).map((l: any) => l.linkId)).toEqual([b.linkId]);
  });

  it("is 404 for someone else's recording, an unknown token and other kinds of token", async () => {
    expect((await create(randomUUID())).status).toBe(404);
    expect((await lookup(`osbf_${randomBytes(32).toString('base64url')}`)).status).toBe(404);
    // A phone's device token is in the same table: it is not a footage link.
    expect((await lookup(main.token)).status).toBe(400);
    expect((await lookup(undefined)).status).toBe(400);
  });

  it('allows ten open links for a recording', async () => {
    for (let i = 0; i < 10; i++) expect((await create()).status).toBe(201);
    expect((await create()).status).toBe(409);
  });

  it('stops working, and leaves no token behind, when the recording, game or account is deleted', async () => {
    const deletes: Array<() => Promise<{ status: number }>> = [
      () => callWeb(alice, 'DELETE /games/{gameId}/recordings/{recordingId}', { path: path() }),
      () => callWeb(alice, 'DELETE /games/{gameId}', { path: { gameId } }),
      () => callWeb(alice, 'DELETE /me'),
    ];
    for (const [i, del] of deletes.entries()) {
      if (i > 0) {
        // The last round deleted it: record again as a new game.
        gameId = randomUUID();
        recordingId = randomUUID();
        expect((await uploadFile(main, gameId, recordingId, 0, files[0]!)).status).toBe(200);
      }
      const { token } = (await create()).body;
      expect((await lookup(token)).status).toBe(200);
      expect((await del()).status).toBe(204);
      expect((await lookup(token)).status).toBe(404);
      expect(await tokenItem(token)).toBeUndefined();
    }
  });
});
