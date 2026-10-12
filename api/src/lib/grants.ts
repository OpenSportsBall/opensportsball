// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Recording grants: Main, with its device token, lets another phone
 *  upload that phone's own report and segments for one game into Main's
 *  account. The other phone stays linked to its own account, if any.
 *
 *  A grant token can only call the report and upload routes, only for its
 *  game, and only as its device (handlers/device.ts). It expires after
 *  GRANT_TTL_MS. Asking again for the same game and phone replaces it. */

import { GetCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import { config, ddb, keys } from './store.js';
import { GRANT_TTL_MS, hashToken, newGrantToken } from './tokens.js';

/** The `TOKEN#` item of a grant token. */
export interface GrantTokenItem {
  kind: 'grant';
  accountId: string;
  deviceId: string;
  gameId: string;
  expiresAtMs: number;
}

/** The account's record of a grant, for checking manifests and listing. */
export interface GrantItem {
  gameId: string;
  deviceId: string;
  tokenHash: string;
  issuedBy: string;
  createdAt: string;
  expiresAt: string;
}

export async function getGrant(acct: string, gameId: string, deviceId: string) {
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.grant(acct, gameId, deviceId) }));
  return r.Item as GrantItem | undefined;
}

/** [issuedBy] is Main's deviceId; [apiDomain] the domain the request came
 *  in on, which the other phone needs too. */
export async function createGrant(o: {
  accountId: string;
  gameId: string;
  deviceId: string;
  issuedBy: string;
  apiDomain: string;
}) {
  const now = Date.now();
  const expiresAtMs = now + GRANT_TTL_MS;
  const token = newGrantToken();
  const tokenHash = hashToken(token);
  const previous = await getGrant(o.accountId, o.gameId, o.deviceId);
  const tokenItem: GrantTokenItem = {
    kind: 'grant',
    accountId: o.accountId,
    deviceId: o.deviceId,
    gameId: o.gameId,
    expiresAtMs,
  };
  const grant: GrantItem = {
    gameId: o.gameId,
    deviceId: o.deviceId,
    tokenHash,
    issuedBy: o.issuedBy,
    createdAt: new Date(now).toISOString(),
    expiresAt: new Date(expiresAtMs).toISOString(),
  };
  await ddb.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: config.table,
            Item: { ...keys.token(tokenHash), ...tokenItem, ttl: Math.ceil(expiresAtMs / 1000) + 3600 },
          },
        },
        // Kept after the token expires: the manifest check and, later,
        // the Secondary owner's "Contributed to" list use it.
        { Put: { TableName: config.table, Item: { ...keys.grant(o.accountId, o.gameId, o.deviceId), ...grant } } },
        ...(previous ? [{ Delete: { TableName: config.table, Key: keys.token(previous.tokenHash) } }] : []),
      ],
    }),
  );
  return {
    grantToken: token,
    apiUrl: `https://${o.apiDomain}`,
    accountId: o.accountId,
    gameId: o.gameId,
    deviceId: o.deviceId,
    expiresAt: grant.expiresAt,
  };
}
