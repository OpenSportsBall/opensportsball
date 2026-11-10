// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { existsSync } from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';
import { GetObjectCommand, ListObjectsV2Command, S3Client } from '@aws-sdk/client-s3';
import { CognitoIdentityProviderClient, CreateUserPoolCommand } from '@aws-sdk/client-cognito-identity-provider';
import { beforeEach, describe, expect, it } from 'vitest';
import { CONSENT_VERSIONS } from '../src/lib/contributions.js';
import { callDevice, callWeb, linkPhone, manifest, readyEvents, resetAws, sha, type Phone } from './helpers.js';

const s3 = new S3Client({ forcePathStyle: true });
const BUCKET = process.env.CONTRIBUTIONS_BUCKET_NAME!;

/** What `engine.py share` writes, for these files. */
function share(gameId: string, files: Record<string, Buffer>, kind = 'pitch') {
  return {
    schemaVersion: 1,
    name: kind,
    kind,
    recording: { gameId, sessionId: randomUUID(), createdAt: '2026-11-05T06:07:37Z' },
    engine: { version: 'abc1234' },
    createdAt: '2026-11-09T12:28:07-0800',
    summary: { approvedFirstGuess: false, corrections: 1 },
    files: Object.entries(files).map(([path, b]) => ({ path, bytes: b.length, sha256: sha(b) })),
  };
}

async function put(upload: { url: string; headers: Record<string, string> }, data: Buffer) {
  const r = await fetch(upload.url, { method: 'PUT', headers: upload.headers, body: new Uint8Array(data) });
  return r.status;
}

async function keysUnder(prefix: string) {
  const r = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: prefix }));
  return (r.Contents ?? []).map((o) => o.Key!).sort();
}

describe('contributions', () => {
  let alice: string;
  let main: Phone;
  let gameId: string;
  let recordingId: string;
  const files = { 'pitch/pitch.json': Buffer.from('{"lengthM": 102.4}'), 'pitch/background.png': randomBytes(300) };

  beforeEach(async () => {
    await resetAws();
    // DELETE /me also deletes the sign-in.
    const pool = await new CognitoIdentityProviderClient({}).send(new CreateUserPoolCommand({ PoolName: `osb-${randomUUID()}` }));
    process.env.USER_POOL_ID = pool.UserPool!.Id!;
    alice = randomUUID();
    main = await linkPhone(alice);
    gameId = randomUUID();
    recordingId = randomUUID();
    const m = await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
      path: { gameId, recordingId },
      body: manifest(gameId, recordingId, main, [randomBytes(50)]),
    });
    expect(m.status).toBe(200);
    await readyEvents();
  });

  const create = (acct = alice, extra: Record<string, unknown> = {}) =>
    callWeb(acct, 'POST /contributions', {
      body: { gameId, recordingId, consentVersion: 'share-v1', contribution: share(gameId, files), ...extra },
    });

  it('uploads each file to a signed URL, checks them, and publishes ContributionReady', async () => {
    const c = await create();
    expect(c.status).toBe(201);
    expect(c.body).toMatchObject({ status: 'uploading', kind: 'pitch', files: 2, consentVersion: 'share-v1', gameId });
    const id = c.body.contributionId;

    // Not complete until every file is there.
    expect((await callWeb(alice, 'POST /contributions/{contributionId}/complete', { path: { contributionId: id } })).status).toBe(409);
    for (const u of c.body.uploads) expect(await put(u, files[u.path as keyof typeof files])).toBe(200);
    const done = await callWeb(alice, 'POST /contributions/{contributionId}/complete', { path: { contributionId: id } });
    expect(done.status).toBe(200);
    expect(done.body.status).toBe('complete');

    expect(await keysUnder(`contributions/${alice}/${id}/`)).toEqual([
      `contributions/${alice}/${id}/contribution.json`,
      `contributions/${alice}/${id}/files/pitch/background.png`,
      `contributions/${alice}/${id}/files/pitch/pitch.json`,
    ]);
    const doc = JSON.parse(
      await (await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: `contributions/${alice}/${id}/contribution.json` }))).Body!.transformToString(),
    );
    expect(doc).toMatchObject({ consentVersion: 'share-v1', status: 'complete', contribution: { kind: 'pitch' } });
    const ev = await readyEvents();
    expect(ev).toEqual([expect.objectContaining({ accountId: alice, contributionId: id, kind: 'pitch', bucket: BUCKET })]);

    const list = await callWeb(alice, 'GET /contributions');
    expect(list.body.contributions.map((x: any) => [x.contributionId, x.status])).toEqual([[id, 'complete']]);
  });

  it("signs each file's size and SHA-256 into its URL, so S3 refuses other bytes", async () => {
    // S3 checks the body against x-amz-checksum-sha256 (BadDigest); the local
    // emulator doesn't, so this checks what the API controls: the header is
    // signed (another value breaks the signature) and the value is the file's.
    const c = await create();
    for (const u of c.body.uploads) {
      const signed = new URL(u.url).searchParams.get('X-Amz-SignedHeaders')!.split(';');
      expect(signed).toEqual(expect.arrayContaining(['x-amz-checksum-sha256', 'content-length']));
      const b = files[u.path as keyof typeof files];
      expect(u.headers['x-amz-checksum-sha256']).toBe(Buffer.from(sha(b), 'hex').toString('base64'));
    }
  });

  it('is withdrawn with DELETE, and goes when the account is deleted, not when the game is', async () => {
    const a = await create();
    for (const u of a.body.uploads) await put(u, files[u.path as keyof typeof files]);
    await callWeb(alice, 'POST /contributions/{contributionId}/complete', { path: { contributionId: a.body.contributionId } });
    const b = await create();

    // Deleting the game keeps what was shared (it is kept apart, as the privacy policy says).
    expect((await callWeb(alice, 'DELETE /games/{gameId}', { path: { gameId } })).status).toBe(204);
    expect((await callWeb(alice, 'GET /contributions')).body.contributions).toHaveLength(2);

    expect((await callWeb(alice, 'DELETE /contributions/{contributionId}', { path: { contributionId: a.body.contributionId } })).status).toBe(204);
    expect(await keysUnder(`contributions/${alice}/${a.body.contributionId}/`)).toEqual([]);
    expect((await callWeb(alice, 'GET /contributions')).body.contributions.map((x: any) => x.contributionId)).toEqual([
      b.body.contributionId,
    ]);

    expect((await callWeb(alice, 'DELETE /me')).status).toBe(204);
    expect(await keysUnder(`contributions/${alice}/`)).toEqual([]);
  });

  it("refuses someone else's recording, unknown consent, bad paths and bad files", async () => {
    expect((await create(randomUUID())).status).toBe(404); // another account
    expect((await create(alice, { consentVersion: 'share-v0' })).status).toBe(400);
    for (const path of ['../escape.json', '/abs.json', 'a/../../b.json', '.hidden', 'a//b']) {
      const bad = share(gameId, { [path]: Buffer.from('x') });
      expect((await create(alice, { contribution: bad })).status, path).toBe(400);
    }
    const dup = share(gameId, files);
    dup.files.push(dup.files[0]!);
    expect((await create(alice, { contribution: dup })).status).toBe(400);
    expect((await create(alice, { contribution: { ...share(gameId, files), kind: 'video' } })).body.error).toBe('invalid_contribution');
    expect((await create(alice, { contribution: share(randomUUID(), files) })).status).toBe(400); // another game
    // Bob can't see, complete or withdraw Alice's.
    const a = await create();
    const bob = randomUUID();
    const path = { contributionId: a.body.contributionId };
    expect((await callWeb(bob, 'POST /contributions/{contributionId}/complete', { path })).status).toBe(404);
    expect((await callWeb(bob, 'DELETE /contributions/{contributionId}', { path })).status).toBe(404);
    expect((await callWeb(bob, 'GET /contributions')).body.contributions).toEqual([]);
  });

  it('has the wording for every consent version it accepts', () => {
    for (const v of CONSENT_VERSIONS) {
      expect(existsSync(new URL(`../../shared/consent/${v}.md`, import.meta.url)), v).toBe(true);
    }
  });
});
