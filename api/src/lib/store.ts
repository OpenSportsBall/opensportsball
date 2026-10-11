// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * AWS clients, configuration, and the single-table DynamoDB layout.
 *
 * | pk                  | sk                                      | item                    |
 * |---------------------|-----------------------------------------|-------------------------|
 * | LINKCODE#<code>     | LINKCODE                                | pending phone link      |
 * | TOKEN#<sha256>      | TOKEN                                   | device token -> device  |
 * | DEVICE#<deviceId>   | OWNER                                   | which account owns it   |
 * | ACCOUNT#<acct>      | DEVICE#<deviceId>                       | linked phone            |
 * | ACCOUNT#<acct>      | GAME#<gameId>                           | game                    |
 * | ACCOUNT#<acct>      | REC#<gameId>#<recordingId>              | recording + manifest    |
 * | ACCOUNT#<acct>      | OBJ#<gameId>#<recordingId>#<dev>#<file> | uploaded segment        |
 * | ACCOUNT#<acct>      | UPLOAD#<gameId>#<recordingId>#<file>    | multipart in progress   |
 */

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, QueryCommand, type QueryCommandInput } from '@aws-sdk/lib-dynamodb';
import { EventBridgeClient } from '@aws-sdk/client-eventbridge';
import { S3Client } from '@aws-sdk/client-s3';

export const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});
// Path-style addressing only for the local S3 emulator used in tests.
export const s3 = new S3Client({ forcePathStyle: process.env.S3_FORCE_PATH_STYLE === '1' });
export const events = new EventBridgeClient({});

function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined) throw new Error(`missing environment variable ${name}`);
  return v;
}

export const config = {
  get table() {
    return env('TABLE_NAME');
  },
  get bucket() {
    return env('BUCKET_NAME');
  },
  get eventBus() {
    return env('EVENT_BUS_NAME', 'default');
  },
  get partSizeBytes() {
    return Number(env('PART_SIZE_BYTES', String(64 * 1024 * 1024)));
  },
  get urlTtlSeconds() {
    return Number(env('URL_TTL_SECONDS', String(6 * 3600)));
  },
};

export const keys = {
  linkCode: (code: string) => ({ pk: `LINKCODE#${code}`, sk: 'LINKCODE' }),
  token: (hash: string) => ({ pk: `TOKEN#${hash}`, sk: 'TOKEN' }),
  owner: (deviceId: string) => ({ pk: `DEVICE#${deviceId}`, sk: 'OWNER' }),
  device: (acct: string, deviceId: string) => ({ pk: `ACCOUNT#${acct}`, sk: `DEVICE#${deviceId}` }),
  game: (acct: string, gameId: string) => ({ pk: `ACCOUNT#${acct}`, sk: `GAME#${gameId}` }),
  recording: (acct: string, gameId: string, recId: string) => ({
    pk: `ACCOUNT#${acct}`,
    sk: `REC#${gameId}#${recId}`,
  }),
  object: (acct: string, gameId: string, recId: string, deviceId: string, fileName: string) => ({
    pk: `ACCOUNT#${acct}`,
    sk: `OBJ#${gameId}#${recId}#${deviceId}#${fileName}`,
  }),
  upload: (acct: string, gameId: string, recId: string, fileName: string) => ({
    pk: `ACCOUNT#${acct}`,
    sk: `UPLOAD#${gameId}#${recId}#${fileName}`,
  }),
};

/** All items in one account whose sort key starts with [prefix]. */
export async function queryPrefix<T>(acct: string, prefix: string): Promise<T[]> {
  const items: T[] = [];
  let start: QueryCommandInput['ExclusiveStartKey'];
  do {
    const page = await ddb.send(
      new QueryCommand({
        TableName: config.table,
        KeyConditionExpression: 'pk = :pk AND begins_with(sk, :prefix)',
        ExpressionAttributeValues: { ':pk': `ACCOUNT#${acct}`, ':prefix': prefix },
        ExclusiveStartKey: start,
      }),
    );
    items.push(...((page.Items ?? []) as T[]));
    start = page.LastEvaluatedKey;
  } while (start);
  return items;
}

// --- S3 layout --------------------------------------------------------------

export const recordingPrefix = (acct: string, gameId: string, recId: string) =>
  `accounts/${acct}/games/${gameId}/recordings/${recId}/`;

export const segmentKey = (acct: string, gameId: string, recId: string, deviceId: string, fileName: string) =>
  `${recordingPrefix(acct, gameId, recId)}${deviceId}/${fileName}`;

export const manifestKey = (acct: string, gameId: string, recId: string) =>
  `${recordingPrefix(acct, gameId, recId)}manifest.json`;

const SEGMENT_KEY =
  /^accounts\/([^/]+)\/games\/([0-9a-f-]{36})\/recordings\/([0-9a-f-]{36})\/([0-9a-f-]{36})\/([0-9a-f-]{36}_[0-9]{3}\.mp4)$/;

export function parseSegmentKey(key: string) {
  const m = SEGMENT_KEY.exec(key);
  if (!m) return null;
  const [, accountId, gameId, recordingId, deviceId, fileName] = m as unknown as [string, string, string, string, string, string];
  if (!fileName.startsWith(`${deviceId}_`)) return null;
  return { accountId, gameId, recordingId, deviceId, fileName };
}

/** A phone may only upload its own files: `<deviceId>_<3 digits>.mp4`. */
export const segmentFileName = (deviceId: string) => new RegExp(`^${deviceId}_[0-9]{3}\\.mp4$`);
