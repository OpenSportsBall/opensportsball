// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { createVerify, generateKeyPairSync } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { deployedFootageSigner, footageSigner } from '../src/lib/footageUrls.js';

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const signer = footageSigner({
  domain: 'd111.cloudfront.net',
  keyPairId: 'K2TESTKEY',
  privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
});
const expiresAt = new Date('2026-11-08T12:00:00Z');
const epoch = Math.floor(expiresAt.getTime() / 1000);

/** CloudFront's URL-safe base64 back to bytes. */
const unCloudFront = (s: string) => Buffer.from(s.replace(/-/g, '+').replace(/_/g, '=').replace(/~/g, '/'), 'base64');

const verifies = (policy: string, signature: string) =>
  createVerify('RSA-SHA256').update(policy).verify(publicKey, unCloudFront(signature));

describe('footage URLs', () => {
  it('signs one object, with SHA-256, so the public key verifies it', () => {
    const key = 'accounts/a1/games/g1/recordings/r1/dev 1/dev 1_003.mp4';
    const u = new URL(signer.url(key, expiresAt));
    expect(u.origin).toBe('https://d111.cloudfront.net');
    expect(u.pathname).toBe('/accounts/a1/games/g1/recordings/r1/dev%201/dev%201_003.mp4');
    expect(u.searchParams.get('Expires')).toBe(String(epoch));
    expect(u.searchParams.get('Key-Pair-Id')).toBe('K2TESTKEY');
    expect(u.searchParams.get('Hash-Algorithm')).toBe('SHA256');
    const resource = `https://d111.cloudfront.net${u.pathname}`;
    const canned = JSON.stringify({
      Statement: [{ Resource: resource, Condition: { DateLessThan: { 'AWS:EpochTime': epoch } } }],
    });
    expect(verifies(canned, u.searchParams.get('Signature')!)).toBe(true);
  });

  it('signs cookies for everything under one recording, and nothing wider', () => {
    const c = signer.cookies('accounts/a1/games/g1/recordings/r1/', expiresAt);
    expect(c['CloudFront-Key-Pair-Id']).toBe('K2TESTKEY');
    const policy = unCloudFront(c['CloudFront-Policy']!).toString();
    expect(JSON.parse(policy)).toEqual({
      Statement: [
        {
          Resource: 'https://d111.cloudfront.net/accounts/a1/games/g1/recordings/r1/*',
          Condition: { DateLessThan: { 'AWS:EpochTime': epoch } },
        },
      ],
    });
    expect(verifies(policy, c['CloudFront-Signature'])).toBe(true);
  });

  it('refuses a cookie prefix that would match more than a folder', () => {
    expect(() => signer.cookies('accounts/a1', expiresAt)).toThrow(/must end in/);
    expect(() => signer.url('/accounts/a1/x.mp4', expiresAt)).toThrow(/must not start/);
  });

  it('says so when the deployment has no footage distribution', async () => {
    delete process.env.FOOTAGE_CDN_DOMAIN;
    await expect(deployedFootageSigner()).rejects.toThrow(/not configured/);
  });
});
