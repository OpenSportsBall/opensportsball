// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** HTTP API Lambda authorizer for phone routes: looks up the hash of a
 *  device token or a recording grant token (lib/grants.ts). Not cached, so
 *  unlinking a phone takes effect immediately.
 *
 *  An HTTP API turns an authorizer "deny" into `403 {"message":"Forbidden"}`,
 *  but phones need `401` to know they were unlinked (docs/API.md). So an
 *  unknown or expired token is passed through with an empty identity, and
 *  the device handler answers 401 for any request without one. */

import { GetCommand } from '@aws-sdk/lib-dynamodb';
import type {
  APIGatewayRequestAuthorizerEventV2,
  APIGatewaySimpleAuthorizerWithContextResult,
} from 'aws-lambda';
import type { DeviceContext } from './device.js';
import type { GrantTokenItem } from '../lib/grants.js';
import { config, ddb, keys } from '../lib/store.js';
import { DEVICE_TOKEN, GRANT_TOKEN, hashToken } from '../lib/tokens.js';

type Result = APIGatewaySimpleAuthorizerWithContextResult<DeviceContext>;

/** No identity: the device handler rejects it with 401. */
export const ANONYMOUS: Result = { isAuthorized: true, context: { accountId: '', deviceId: '' } };

export async function handler(event: APIGatewayRequestAuthorizerEventV2): Promise<Result> {
  const header = event.headers?.authorization ?? event.headers?.Authorization ?? '';
  const token = /^Bearer (\S+)$/.exec(header)?.[1];
  if (!token || !(DEVICE_TOKEN.test(token) || GRANT_TOKEN.test(token))) return ANONYMOUS;
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.token(hashToken(token)) }));
  const item = r.Item as (DeviceContext & Partial<GrantTokenItem>) | undefined;
  if (!item) return ANONYMOUS;
  if (item.kind === 'grant') {
    // DynamoDB's TTL deletes late, so check expiry here.
    if (!item.gameId || !(Number(item.expiresAtMs) > Date.now())) return ANONYMOUS;
    return {
      isAuthorized: true,
      context: { accountId: item.accountId, deviceId: item.deviceId, grantGameId: item.gameId },
    };
  }
  return { isAuthorized: true, context: { accountId: item.accountId, deviceId: item.deviceId } };
}
