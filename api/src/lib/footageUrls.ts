// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Signed CloudFront URLs and cookies for downloading footage (infra/README.md,
 * "Footage downloads"). The footage distribution serves nothing unsigned, so
 * these are the only way in: sign only keys under an account's own prefixes
 * (store.ts: recordingPrefix, segmentKey), after checking who is asking.
 *
 * The private key is read from SSM once per Lambda instance. Signatures use
 * SHA-256.
 */

import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm';
import { getSignedCookies, getSignedUrl, type CloudfrontSignedCookiesOutput } from '@aws-sdk/cloudfront-signer';
import { ApiError } from './http.js';

const ssm = new SSMClient({});

export interface FootageSigner {
  /** The CloudFront address of one object, e.g. a segment, signed until expiresAt. */
  url(key: string, expiresAt: Date): string;
  /** Cookies for every object under prefix (which must end in "/"), until expiresAt. */
  cookies(prefix: string, expiresAt: Date): CloudfrontSignedCookiesOutput;
}

interface SignerConfig {
  domain: string;
  keyPairId: string;
  privateKey: string;
}

/** Each path segment encoded, the "/" between them kept. */
const encodeKey = (key: string) => key.split('/').map(encodeURIComponent).join('/');

export function footageSigner({ domain, keyPairId, privateKey }: SignerConfig): FootageSigner {
  const base = `https://${domain}/`;
  const creds = { keyPairId, privateKey, algorithm: 'SHA256' as const };
  return {
    url(key, expiresAt) {
      if (key.startsWith('/')) throw new Error(`footage key must not start with "/": ${key}`);
      return getSignedUrl({ ...creds, url: base + encodeKey(key), dateLessThan: expiresAt });
    },
    cookies(prefix, expiresAt) {
      if (!prefix.endsWith('/') || prefix.startsWith('/')) throw new Error(`footage prefix must end in "/": ${prefix}`);
      const policy = JSON.stringify({
        Statement: [
          {
            Resource: `${base}${encodeKey(prefix)}*`,
            Condition: { DateLessThan: { 'AWS:EpochTime': Math.floor(expiresAt.getTime() / 1000) } },
          },
        ],
      });
      return getSignedCookies({ ...creds, policy });
    },
  };
}

let cached: Promise<FootageSigner> | undefined;

/** The signer for this deployment, from the environment the stack sets
 *  (FOOTAGE_CDN_DOMAIN, FOOTAGE_KEY_PAIR_ID, FOOTAGE_SIGNING_KEY_PARAM).
 *  A 503 when the stack has no footage distribution. */
export function deployedFootageSigner(): Promise<FootageSigner> {
  cached ??= (async () => {
    const { FOOTAGE_CDN_DOMAIN: domain, FOOTAGE_KEY_PAIR_ID: keyPairId, FOOTAGE_SIGNING_KEY_PARAM: name } = process.env;
    if (!domain || !keyPairId || !name) {
      throw new ApiError(503, 'downloads_unavailable', 'Footage downloads are not configured on this server.');
    }
    const r = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
    const privateKey = r.Parameter?.Value;
    if (!privateKey) throw new Error(`SSM parameter ${name} is empty`);
    return footageSigner({ domain, keyPairId, privateKey });
  })().catch((e) => {
    cached = undefined; // try again on the next request
    throw e;
  });
  return cached;
}
