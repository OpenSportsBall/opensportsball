// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * AWS clients, configuration, and the single-table DynamoDB layout.
 *
 * | pk                  | sk                                      | item                    |
 * |---------------------|-----------------------------------------|-------------------------|
 * | LINKCODE#<code>     | LINKCODE                                | pending phone link      |
 * | TOKEN#<sha256>      | TOKEN                                   | device token -> device, |
 * |                     |                                         | or grant token -> grant |
 * | DEVICE#<deviceId>   | OWNER                                   | which account owns it   |
 * | ACCOUNT#<acct>      | DEVICE#<deviceId>                       | linked phone            |
 * | ACCOUNT#<acct>      | GAME#<gameId>                           | game                    |
 * | ACCOUNT#<acct>      | GRANT#<gameId>#<deviceId>               | recording grant         |
 * | ACCOUNT#<acct>      | TICKET#<sha256>                         | unbound grant ticket    |
 * | ACCOUNT#<acct>      | REC#<gameId>#<recordingId>              | recording + manifest    |
 * | ACCOUNT#<acct>      | REPORT#<gameId>#<recordingId>#<dev>     | a phone's own segments  |
 * | ACCOUNT#<acct>      | OBJ#<gameId>#<recordingId>#<dev>#<file> | uploaded segment        |
 * | ACCOUNT#<acct>      | UPLOAD#<gameId>#<recordingId>#<file>    | multipart in progress   |
 * | ACCOUNT#<acct>      | DELETED#<gameId>                        | deleted game            |
 * | ACCOUNT#<acct>      | DELETED#<gameId>#<recordingId>          | deleted recording       |
 * | ACCOUNT#<acct>      | CLOSED                                  | deleted account         |
 * | ACCOUNT#<acct>      | CONTRIB#<contributionId>                | shared result (models)  |
 */

import { CognitoIdentityProviderClient } from '@aws-sdk/client-cognito-identity-provider';
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
export const cognito = new CognitoIdentityProviderClient({});

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
  /** Shared results (lib/contributions.ts): apart from footage, with their own retention. */
  get contributionsBucket() {
    return env('CONTRIBUTIONS_BUCKET_NAME');
  },
  /** The same, or null in a deployment without one (account deletion skips it). */
  get contributionsBucketOrNull(): string | null {
    return process.env.CONTRIBUTIONS_BUCKET_NAME ?? null;
  },
  get userPoolId() {
    return env('USER_POOL_ID');
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
  /** How long footage download links last: long enough for a whole game
   *  on a slow connection. */
  get downloadUrlTtlSeconds() {
    return Number(env('DOWNLOAD_URL_TTL_SECONDS', String(12 * 3600)));
  },
};

export const keys = {
  linkCode: (code: string) => ({ pk: `LINKCODE#${code}`, sk: 'LINKCODE' }),
  token: (hash: string) => ({ pk: `TOKEN#${hash}`, sk: 'TOKEN' }),
  owner: (deviceId: string) => ({ pk: `DEVICE#${deviceId}`, sk: 'OWNER' }),
  device: (acct: string, deviceId: string) => ({ pk: `ACCOUNT#${acct}`, sk: `DEVICE#${deviceId}` }),
  game: (acct: string, gameId: string) => ({ pk: `ACCOUNT#${acct}`, sk: `GAME#${gameId}` }),
  grant: (acct: string, gameId: string, deviceId: string) => ({
    pk: `ACCOUNT#${acct}`,
    sk: `GRANT#${gameId}#${deviceId}`,
  }),
  ticket: (acct: string, hash: string) => ({ pk: `ACCOUNT#${acct}`, sk: `TICKET#${hash}` }),
  recording: (acct: string, gameId: string, recId: string) => ({
    pk: `ACCOUNT#${acct}`,
    sk: `REC#${gameId}#${recId}`,
  }),
  report: (acct: string, gameId: string, recId: string, deviceId: string) => ({
    pk: `ACCOUNT#${acct}`,
    sk: `REPORT#${gameId}#${recId}#${deviceId}`,
  }),
  object: (acct: string, gameId: string, recId: string, deviceId: string, fileName: string) => ({
    pk: `ACCOUNT#${acct}`,
    sk: `OBJ#${gameId}#${recId}#${deviceId}#${fileName}`,
  }),
  upload: (acct: string, gameId: string, recId: string, fileName: string) => ({
    pk: `ACCOUNT#${acct}`,
    sk: `UPLOAD#${gameId}#${recId}#${fileName}`,
  }),
  /** Kept after a delete so phones still uploading are refused, not let
   *  in to recreate it (lib/deletion.ts). */
  deletedGame: (acct: string, gameId: string) => ({ pk: `ACCOUNT#${acct}`, sk: `DELETED#${gameId}` }),
  deletedRecording: (acct: string, gameId: string, recId: string) => ({
    pk: `ACCOUNT#${acct}`,
    sk: `DELETED#${gameId}#${recId}`,
  }),
  /** Left when an account is deleted (lib/deletion.ts), so a link code or
   *  an upload already under way can't bring it back. */
  closedAccount: (acct: string) => ({ pk: `ACCOUNT#${acct}`, sk: 'CLOSED' }),
  contribution: (acct: string, id: string) => ({ pk: `ACCOUNT#${acct}`, sk: `CONTRIB#${id}` }),
};

/** All items in one account whose sort key starts with [prefix], or all
 *  of them when [prefix] is empty. */
export async function queryPrefix<T>(acct: string, prefix: string): Promise<T[]> {
  const items: T[] = [];
  let start: QueryCommandInput['ExclusiveStartKey'];
  do {
    const page = await ddb.send(
      new QueryCommand({
        TableName: config.table,
        KeyConditionExpression: prefix ? 'pk = :pk AND begins_with(sk, :prefix)' : 'pk = :pk',
        ExpressionAttributeValues: { ':pk': `ACCOUNT#${acct}`, ...(prefix ? { ':prefix': prefix } : {}) },
        ExclusiveStartKey: start,
      }),
    );
    items.push(...((page.Items ?? []) as T[]));
    start = page.LastEvaluatedKey;
  } while (start);
  return items;
}

// --- S3 layout --------------------------------------------------------------

export const accountPrefix = (acct: string) => `accounts/${acct}/`;

export const gamePrefix = (acct: string, gameId: string) => `${accountPrefix(acct)}games/${gameId}/`;

export const recordingPrefix = (acct: string, gameId: string, recId: string) =>
  `${gamePrefix(acct, gameId)}recordings/${recId}/`;

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
