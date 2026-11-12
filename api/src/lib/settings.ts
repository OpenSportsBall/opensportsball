// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** What an account may do beyond the default. Today one switch: cloud
 *  processing, which an admin turns on per account until it is paid for
 *  (docs/CLOUD-PROCESSING-PLAN.md). */

import { GetCommand, PutCommand } from '@aws-sdk/lib-dynamodb';
import { config, ddb, keys } from './store.js';

export interface Settings {
  cloudProcessing: boolean;
}

export async function getSettings(acct: string): Promise<Settings> {
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.settings(acct) }));
  return { cloudProcessing: r.Item?.cloudProcessing === true };
}

export async function setCloudProcessing(acct: string, enabled: boolean, by: string) {
  await ddb.send(
    new PutCommand({
      TableName: config.table,
      Item: { ...keys.settings(acct), cloudProcessing: enabled, updatedAt: new Date().toISOString(), updatedBy: by },
    }),
  );
}
