// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Unlinking a phone from its account: from the website, or by the phone
 *  itself. */

import { GetCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import { notFound } from './http.js';
import { config, ddb, keys } from './store.js';

export interface DeviceItem {
  deviceId: string;
  platform: string;
  model: string;
  linkedAt: string;
  lastSeenAt?: string;
  tokenHash: string;
}

/** Removes the phone, its ownership and its token, so it can join another
 *  account. Its recordings stay. */
export async function unlinkDevice(acct: string, deviceId: string) {
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.device(acct, deviceId) }));
  const device = r.Item as DeviceItem | undefined;
  if (!device) throw notFound('No such device on this account.');
  await ddb.send(
    new TransactWriteCommand({
      TransactItems: [
        { Delete: { TableName: config.table, Key: keys.device(acct, deviceId) } },
        { Delete: { TableName: config.table, Key: keys.owner(deviceId) } },
        { Delete: { TableName: config.table, Key: keys.token(device.tokenHash) } },
      ],
    }),
  );
}
