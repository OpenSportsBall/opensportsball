// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Single-use codes that link a phone to an account, created on the
 *  website. */

import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import { PutCommand } from '@aws-sdk/lib-dynamodb';
import { config, ddb, keys } from './store.js';
import { LINK_CODE_TTL_MS, newLinkCode } from './tokens.js';

export interface LinkCode {
  code: string;
  expiresAt: string;
  linkUri: string;
}

/** [apiDomain] is the domain the request came in on; the phone needs it too. */
export async function createLinkCode(acct: string, apiDomain: string): Promise<LinkCode> {
  const expiresAtMs = Date.now() + LINK_CODE_TTL_MS;
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = newLinkCode();
    try {
      await ddb.send(
        new PutCommand({
          TableName: config.table,
          Item: {
            ...keys.linkCode(code),
            accountId: acct,
            expiresAtMs,
            ttl: Math.ceil(expiresAtMs / 1000) + 3600,
          },
          ConditionExpression: 'attribute_not_exists(pk)',
        }),
      );
      const apiUrl = `https://${apiDomain}`;
      return {
        code,
        expiresAt: new Date(expiresAtMs).toISOString(),
        linkUri: `opensportsball://link?v=1&api=${encodeURIComponent(apiUrl)}&code=${code}`,
      };
    } catch (e) {
      if (!(e instanceof ConditionalCheckFailedException)) throw e;
    }
  }
  throw new Error('could not allocate a unique link code');
}
