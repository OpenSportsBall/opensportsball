// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { createVerify, generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { PutParameterCommand, SSMClient } from '@aws-sdk/client-ssm';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { callDevice, callWeb, fileName, linkPhone, manifest, resetAws, sha, uploadFile, type Phone } from './helpers.js';

const CDN = 'd222.cloudfront.net';
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });

/** Whether [url] carries a valid CloudFront canned-policy signature. */
function signedByUs(url: string) {
  const u = new URL(url);
  const policy = JSON.stringify({
    Statement: [
      {
        Resource: `${u.origin}${u.pathname}`,
        Condition: { DateLessThan: { 'AWS:EpochTime': Number(u.searchParams.get('Expires')) } },
      },
    ],
  });
  const sig = u.searchParams.get('Signature')!.replace(/-/g, '+').replace(/_/g, '=').replace(/~/g, '/');
  return createVerify('RSA-SHA256').update(policy).verify(publicKey, Buffer.from(sig, 'base64'));
}

describe('download links', () => {
  let alice: string;
  let main: Phone;
  let gameId: string;
  let recordingId: string;
  const files = [randomBytes(250), randomBytes(120)];
  const downloads = (acct: string, rec = recordingId) =>
    callWeb(acct, 'POST /games/{gameId}/recordings/{recordingId}/downloads', { path: { gameId, recordingId: rec } });

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
    alice = randomUUID();
    main = await linkPhone(alice);
    gameId = randomUUID();
    recordingId = randomUUID();
  });

  it('links every segment and the merged manifest of a ready recording, signed for 12 hours', async () => {
    expect(
      (
        await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
          path: { gameId, recordingId },
          body: manifest(gameId, recordingId, main, files),
        })
      ).status,
    ).toBe(200);
    for (const [i, f] of files.entries()) expect((await uploadFile(main, gameId, recordingId, i, f)).status).toBe(200);

    const before = Date.now();
    const r = await downloads(alice);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('ready');
    const prefix = `https://${CDN}/accounts/${alice}/games/${gameId}/recordings/${recordingId}/`;
    expect(r.body.files.map((f: any) => [f.fileName, f.bytes, f.sha256])).toEqual(
      files.map((f, i) => [fileName(main, i), f.length, sha(f)]),
    );
    for (const [i, f] of r.body.files.entries()) {
      expect(f.url.startsWith(`${prefix}${main.deviceId}/${fileName(main, i)}?`)).toBe(true);
      expect(signedByUs(f.url)).toBe(true);
    }
    expect(r.body.manifestUrl.startsWith(`${prefix}manifest.json?`)).toBe(true);
    expect(signedByUs(r.body.manifestUrl)).toBe(true);
    const hours = (Date.parse(r.body.expiresAt) - before) / 3_600_000;
    expect(hours).toBeGreaterThan(11.9);
    expect(hours).toBeLessThan(12.1);
  });

  it('links what has arrived of an unfinished recording, with no manifest yet', async () => {
    expect((await uploadFile(main, gameId, recordingId, 0, files[0]!)).status).toBe(200);
    const r = await downloads(alice);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('waiting_for_manifest');
    expect(r.body.manifestUrl).toBeNull();
    // No manifest or report has listed it, so there is no checksum to give.
    expect(r.body.files).toEqual([
      expect.objectContaining({ fileName: fileName(main, 0), bytes: files[0]!.length, sha256: null }),
    ]);
  });

  it("is 404 for someone else's recording, and for one that does not exist", async () => {
    expect((await uploadFile(main, gameId, recordingId, 0, files[0]!)).status).toBe(200);
    expect((await downloads(randomUUID())).status).toBe(404);
    expect((await downloads(alice, randomUUID())).status).toBe(404);
  });

  it('is 404 once the recording is deleted', async () => {
    expect((await uploadFile(main, gameId, recordingId, 0, files[0]!)).status).toBe(200);
    expect(
      (await callWeb(alice, 'DELETE /games/{gameId}/recordings/{recordingId}', { path: { gameId, recordingId } })).status,
    ).toBe(204);
    expect((await downloads(alice)).status).toBe(404);
  });
});
