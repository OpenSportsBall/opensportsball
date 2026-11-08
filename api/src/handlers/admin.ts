// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Admin routes (Cognito JWT authorizer, plus membership of the `admins`
 * group). A Lambda of its own, so the website's Lambda never gets to scan
 * the whole table or list every user.
 */

import { ListUsersCommand, type UserType } from '@aws-sdk/client-cognito-identity-provider';
import { ListObjectsV2Command } from '@aws-sdk/client-s3';
import { ScanCommand, type ScanCommandInput } from '@aws-sdk/lib-dynamodb';
import type { APIGatewayProxyEventV2WithJWTAuthorizer } from 'aws-lambda';
import { isAdmin } from '../lib/admin.js';
import { forbidden, json, notFound, respond, type Result } from '../lib/http.js';
import type { RecordingStatus } from '../lib/recordings.js';
import { cognito, config, ddb, s3 } from '../lib/store.js';

export const handler = (event: APIGatewayProxyEventV2WithJWTAuthorizer): Promise<Result> =>
  respond(async () => {
    if (!isAdmin(event.requestContext.authorizer.jwt.claims)) {
      throw forbidden('This page is for OpenSportsBall admins.');
    }
    switch (event.routeKey) {
      case 'GET /admin/accounts':
        return json(200, await accountsReport());
      default:
        throw notFound(`No route ${event.routeKey}.`);
    }
  });

type SignInStatus = 'active' | 'disabled' | 'unconfirmed' | 'deleted' | 'no_sign_in';

export interface AccountRow {
  accountId: string;
  email: string | null;
  /** `deleted`: closed with DELETE /me. `no_sign_in`: table items or
   *  footage for an id with no Cognito user (should not happen). */
  status: SignInStatus;
  createdAt: string | null;
  devices: { deviceId: string; platform: string; model: string; linkedAt: string; lastSeenAt: string | null }[];
  games: number;
  recordings: Record<RecordingStatus, number> & { total: number };
  /** Everything under accounts/<id>/ in the footage bucket. */
  storageBytes: number;
  objectCount: number;
  /** Newest and oldest object; the oldest expires first (180 days). */
  lastUploadAt: string | null;
  oldestObjectAt: string | null;
}

async function accountsReport() {
  const [users, items, objects] = await Promise.all([listUsers(), scanAccountItems(), listAccountObjects()]);
  const rows = new Map<string, AccountRow>();
  const row = (id: string) => {
    let r = rows.get(id);
    if (!r) {
      r = {
        accountId: id,
        email: null,
        status: 'no_sign_in',
        createdAt: null,
        devices: [],
        games: 0,
        recordings: { total: 0, waiting_for_manifest: 0, uploading: 0, ready: 0 },
        storageBytes: 0,
        objectCount: 0,
        lastUploadAt: null,
        oldestObjectAt: null,
      };
      rows.set(id, r);
    }
    return r;
  };

  for (const u of users) {
    if (!u.Username) continue;
    const r = row(u.Username);
    r.email = u.Attributes?.find((a) => a.Name === 'email')?.Value ?? null;
    r.status = u.Enabled === false ? 'disabled' : u.UserStatus === 'UNCONFIRMED' ? 'unconfirmed' : 'active';
    r.createdAt = u.UserCreateDate?.toISOString() ?? null;
  }

  for (const it of items) {
    const acct = it.pk.slice('ACCOUNT#'.length);
    const sk = it.sk;
    if (sk === 'CLOSED') {
      const r = row(acct);
      r.status = 'deleted';
    } else if (sk.startsWith('DEVICE#')) {
      row(acct).devices.push({
        deviceId: String(it.deviceId),
        platform: String(it.platform),
        model: String(it.model),
        linkedAt: String(it.linkedAt),
        lastSeenAt: typeof it.lastSeenAt === 'string' ? it.lastSeenAt : null,
      });
    } else if (sk.startsWith('GAME#')) {
      row(acct).games++;
    } else if (sk.startsWith('REC#')) {
      const r = row(acct);
      r.recordings.total++;
      const s = it.status as RecordingStatus;
      if (s in r.recordings) r.recordings[s]++;
    }
  }

  for (const o of objects) {
    const m = /^accounts\/([^/]+)\//.exec(o.key);
    if (!m) continue;
    const r = row(m[1]!);
    r.storageBytes += o.size;
    r.objectCount++;
    if (o.lastModified) {
      if (!r.lastUploadAt || o.lastModified > r.lastUploadAt) r.lastUploadAt = o.lastModified;
      if (!r.oldestObjectAt || o.lastModified < r.oldestObjectAt) r.oldestObjectAt = o.lastModified;
    }
  }

  // A deleted account with nothing left is only its CLOSED marker.
  const accounts = [...rows.values()].filter(
    (r) => r.status !== 'deleted' || r.objectCount > 0 || r.games > 0 || r.devices.length > 0,
  );
  accounts.sort((a, b) => b.storageBytes - a.storageBytes || (b.createdAt ?? '').localeCompare(a.createdAt ?? ''));
  const sum = (f: (r: AccountRow) => number) => accounts.reduce((n, r) => n + f(r), 0);
  return {
    generatedAt: new Date().toISOString(),
    totals: {
      accounts: accounts.filter((r) => r.status !== 'deleted').length,
      deletedAccounts: [...rows.values()].filter((r) => r.status === 'deleted').length,
      devices: sum((r) => r.devices.length),
      games: sum((r) => r.games),
      recordings: sum((r) => r.recordings.total),
      storageBytes: sum((r) => r.storageBytes),
      objectCount: sum((r) => r.objectCount),
    },
    accounts,
  };
}

async function listUsers(): Promise<UserType[]> {
  const users: UserType[] = [];
  let token: string | undefined;
  do {
    const page = await cognito.send(new ListUsersCommand({ UserPoolId: config.userPoolId, PaginationToken: token }));
    users.push(...(page.Users ?? []));
    token = page.PaginationToken;
  } while (token);
  return users;
}

interface ScannedItem {
  pk: string;
  sk: string;
  [k: string]: unknown;
}

/** Only the item kinds the report counts, and only the fields it reads
 *  (not manifests). */
async function scanAccountItems(): Promise<ScannedItem[]> {
  const items: ScannedItem[] = [];
  let start: ScanCommandInput['ExclusiveStartKey'];
  do {
    const page = await ddb.send(
      new ScanCommand({
        TableName: config.table,
        FilterExpression:
          'begins_with(pk, :acct) AND (sk = :closed OR begins_with(sk, :dev) OR begins_with(sk, :game) OR begins_with(sk, :rec))',
        ProjectionExpression: 'pk, sk, #status, deviceId, platform, model, linkedAt, lastSeenAt',
        ExpressionAttributeNames: { '#status': 'status' },
        ExpressionAttributeValues: {
          ':acct': 'ACCOUNT#',
          ':closed': 'CLOSED',
          ':dev': 'DEVICE#',
          ':game': 'GAME#',
          ':rec': 'REC#',
        },
        ExclusiveStartKey: start,
      }),
    );
    items.push(...((page.Items ?? []) as ScannedItem[]));
    start = page.LastEvaluatedKey;
  } while (start);
  return items;
}

async function listAccountObjects() {
  const out: { key: string; size: number; lastModified: string | null }[] = [];
  let token: string | undefined;
  do {
    const page = await s3.send(
      new ListObjectsV2Command({ Bucket: config.bucket, Prefix: 'accounts/', ContinuationToken: token }),
    );
    for (const o of page.Contents ?? []) {
      if (o.Key) out.push({ key: o.Key, size: o.Size ?? 0, lastModified: o.LastModified?.toISOString() ?? null });
    }
    token = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (token);
  return out;
}
