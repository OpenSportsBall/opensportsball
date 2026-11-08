// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Admin routes (Cognito JWT authorizer, plus membership of the `admins`
 * group). A Lambda of its own, so the website's Lambda never gets to scan
 * the whole table or list every user.
 */

import { AdminGetUserCommand, ListUsersCommand, UserNotFoundException, type UserType } from '@aws-sdk/client-cognito-identity-provider';
import { ListObjectsV2Command } from '@aws-sdk/client-s3';
import { ScanCommand, type ScanCommandInput } from '@aws-sdk/lib-dynamodb';
import type { APIGatewayProxyEventV2WithJWTAuthorizer } from 'aws-lambda';
import { isAdmin } from '../lib/admin.js';
import { deleteGame, deleteRecording } from '../lib/deletion.js';
import { forbidden, json, notFound, pathParam, respond, type Result } from '../lib/http.js';
import { recordedAt, type RecordingItem, type RecordingStatus, type ReportItem } from '../lib/recordings.js';
import { accountPrefix, cognito, config, ddb, gamePrefix, queryPrefix, recordingPrefix, s3 } from '../lib/store.js';

export const handler = (event: APIGatewayProxyEventV2WithJWTAuthorizer): Promise<Result> =>
  respond(async () => {
    const claims = event.requestContext.authorizer.jwt.claims;
    if (!isAdmin(claims)) {
      throw forbidden('This page is for OpenSportsBall admins.');
    }
    switch (event.routeKey) {
      case 'GET /admin/accounts':
        return json(200, await accountsReport());
      case 'GET /admin/accounts/{accountId}/games':
        return json(200, await accountGames(pathParam(event, 'accountId')));
      case 'DELETE /admin/accounts/{accountId}/games/{gameId}': {
        const acct = pathParam(event, 'accountId');
        const gameId = pathParam(event, 'gameId');
        const footageOnly = await requireSomething(acct, `GAME#${gameId}`, `DELETED#${gameId}`, gamePrefix(acct, gameId), 'game');
        audit(claims, { action: 'delete_game', accountId: acct, gameId });
        await deleteGame(acct, gameId, footageOnly);
        return json(204);
      }
      case 'DELETE /admin/accounts/{accountId}/games/{gameId}/recordings/{recordingId}': {
        const acct = pathParam(event, 'accountId');
        const gameId = pathParam(event, 'gameId');
        const recordingId = pathParam(event, 'recordingId');
        const footageOnly = await requireSomething(
          acct,
          `REC#${gameId}#${recordingId}`,
          `DELETED#${gameId}#${recordingId}`,
          recordingPrefix(acct, gameId, recordingId),
          'recording',
        );
        audit(claims, { action: 'delete_recording', accountId: acct, gameId, recordingId });
        await deleteRecording(acct, gameId, recordingId, footageOnly);
        return json(204);
      }
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

async function listAccountObjects(prefix = 'accounts/') {
  const out: { key: string; size: number; lastModified: string | null }[] = [];
  let token: string | undefined;
  do {
    const page = await s3.send(
      new ListObjectsV2Command({ Bucket: config.bucket, Prefix: prefix, ContinuationToken: token }),
    );
    for (const o of page.Contents ?? []) {
      if (o.Key) out.push({ key: o.Key, size: o.Size ?? 0, lastModified: o.LastModified?.toISOString() ?? null });
    }
    token = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (token);
  return out;
}

/** Every admin delete leaves a line in the Lambda's logs (kept a month):
 *  who, and what. */
function audit(claims: Record<string, unknown>, what: Record<string, string>) {
  console.log(JSON.stringify({ audit: true, admin: String(claims.sub), ...what }));
}

/** 404 unless the table has the item (or its deleted marker, to finish a
 *  delete that failed partway) or the bucket has footage under [prefix].
 *  True when only footage is there. */
async function requireSomething(acct: string, sk: string, deletedSk: string, prefix: string, what: string) {
  const items = await queryPrefix<{ sk: string }>(acct, sk);
  const markers = await queryPrefix<{ sk: string }>(acct, deletedSk);
  if (items.some((i) => i.sk === sk) || markers.some((m) => m.sk === deletedSk)) return false;
  const r = await s3.send(new ListObjectsV2Command({ Bucket: config.bucket, Prefix: prefix, MaxKeys: 1 }));
  if (r.Contents?.length) return true;
  throw notFound(`No such ${what} on that account.`);
}

interface RecordingRow {
  recordingId: string;
  createdAt: string | null;
  recordedAt: string | null;
  /** Null when there is footage but no table item for it. */
  status: RecordingStatus | null;
  hasManifest: boolean;
  storageBytes: number;
  objectCount: number;
  lastUploadAt: string | null;
}

/** One account's games and recordings, with the footage each holds,
 *  including footage in the bucket that the table has no record of. */
async function accountGames(acct: string) {
  const [games, recordings, reports, objects, email] = await Promise.all([
    queryPrefix<{ gameId: string; createdAt: string }>(acct, 'GAME#'),
    queryPrefix<RecordingItem>(acct, 'REC#'),
    queryPrefix<ReportItem>(acct, 'REPORT#'),
    listAccountObjects(accountPrefix(acct)),
    emailOf(acct),
  ]);
  const gameRows = new Map<string, { gameId: string; createdAt: string | null; recordings: Map<string, RecordingRow>; otherBytes: number; otherObjects: number }>();
  const game = (gameId: string) => {
    let g = gameRows.get(gameId);
    if (!g) gameRows.set(gameId, (g = { gameId, createdAt: null, recordings: new Map(), otherBytes: 0, otherObjects: 0 }));
    return g;
  };
  const rec = (gameId: string, recordingId: string) => {
    const g = game(gameId);
    let r = g.recordings.get(recordingId);
    if (!r) {
      r = { recordingId, createdAt: null, recordedAt: null, status: null, hasManifest: false, storageBytes: 0, objectCount: 0, lastUploadAt: null };
      g.recordings.set(recordingId, r);
    }
    return r;
  };
  for (const g of games) game(g.gameId).createdAt = g.createdAt;
  for (const r of recordings) {
    const row = rec(r.gameId, r.recordingId);
    row.createdAt = r.createdAt;
    row.status = r.status;
    row.hasManifest = Boolean(r.manifest);
    row.recordedAt = recordedAt(r, reports.filter((p) => p.gameId === r.gameId && p.recordingId === r.recordingId));
  }
  const prefix = accountPrefix(acct);
  for (const o of objects) {
    const m = /^games\/([^/]+)\/(?:recordings\/([^/]+)\/)?/.exec(o.key.slice(prefix.length));
    if (!m) continue;
    if (!m[2]) {
      const g = game(m[1]!);
      g.otherBytes += o.size;
      g.otherObjects++;
      continue;
    }
    const r = rec(m[1]!, m[2]);
    r.storageBytes += o.size;
    r.objectCount++;
    if (o.lastModified && (!r.lastUploadAt || o.lastModified > r.lastUploadAt)) r.lastUploadAt = o.lastModified;
  }

  const when = (x: { recordedAt: string | null; createdAt: string | null }) => x.recordedAt ?? x.createdAt ?? '';
  const out = [...gameRows.values()].map((g) => {
    const recs = [...g.recordings.values()].sort((a, b) => when(a).localeCompare(when(b)));
    const known = recs.map((r) => r.recordedAt).filter((t): t is string => t !== null).sort();
    return {
      gameId: g.gameId,
      createdAt: g.createdAt,
      recordedAt: known[0] ?? null,
      /** False when the bucket has footage for a game the table doesn't. */
      inTable: g.createdAt !== null,
      storageBytes: recs.reduce((n, r) => n + r.storageBytes, g.otherBytes),
      objectCount: recs.reduce((n, r) => n + r.objectCount, g.otherObjects),
      recordings: recs,
    };
  });
  out.sort((a, b) => when(b).localeCompare(when(a)));
  return { accountId: acct, email, games: out };
}

async function emailOf(acct: string): Promise<string | null> {
  try {
    const u = await cognito.send(new AdminGetUserCommand({ UserPoolId: config.userPoolId, Username: acct }));
    return u.UserAttributes?.find((a) => a.Name === 'email')?.Value ?? null;
  } catch (e) {
    if (e instanceof UserNotFoundException) return null;
    throw e;
  }
}
