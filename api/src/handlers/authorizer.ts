// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/** HTTP API Lambda authorizer for phone routes: looks up the device token's
 *  hash. Not cached, so unlinking a phone takes effect immediately. */

import { GetCommand } from '@aws-sdk/lib-dynamodb';
import type {
  APIGatewayRequestAuthorizerEventV2,
  APIGatewaySimpleAuthorizerWithContextResult,
} from 'aws-lambda';
import type { DeviceContext } from './device.js';
import { config, ddb, keys } from '../lib/store.js';
import { DEVICE_TOKEN, hashToken } from '../lib/tokens.js';

type Result = APIGatewaySimpleAuthorizerWithContextResult<DeviceContext | Record<string, never>>;

const deny: Result = { isAuthorized: false, context: {} };

export async function handler(event: APIGatewayRequestAuthorizerEventV2): Promise<Result> {
  const header = event.headers?.authorization ?? event.headers?.Authorization ?? '';
  const token = /^Bearer (\S+)$/.exec(header)?.[1];
  if (!token || !DEVICE_TOKEN.test(token)) return deny;
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.token(hashToken(token)) }));
  const item = r.Item as DeviceContext | undefined;
  if (!item) return deny;
  return { isAuthorized: true, context: { accountId: item.accountId, deviceId: item.deviceId } };
}
