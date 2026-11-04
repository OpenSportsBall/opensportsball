// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Routes for phones: linking (code as credential) and, with a device
 *  token, unlinking itself, recording grants for a Secondary, Main's manifest,
 *  each phone's report of its own segments, and multipart segment upload.
 *  A recording grant token reaches only the report and upload routes, for
 *  its own game (lib/grants.ts). */

import { createHash } from 'node:crypto';
import { TransactionCanceledException } from '@aws-sdk/client-dynamodb';
import {
  AbortMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  HeadObjectCommand,
  ListPartsCommand,
  NoSuchUpload,
  NotFound,
  UploadPartCommand,
  type Part,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { DeleteCommand, GetCommand, PutCommand, TransactWriteCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import type { APIGatewayProxyEventV2, APIGatewayProxyEventV2WithLambdaAuthorizer } from 'aws-lambda';
import {
  ApiError,
  SHA256_HEX,
  UUID,
  badRequest,
  body,
  conflict,
  forbidden,
  gone,
  int,
  json,
  notFound,
  pathParam,
  respond,
  str,
  type Result,
} from '../lib/http.js';
import { isClosed, refuseDeleted } from '../lib/deletion.js';
import { unlinkDevice } from '../lib/devices.js';
import { createGrant, createTickets, getGrant, lookupGameTicket, redeemTicket } from '../lib/grants.js';
import { parseManifest, parseReport, type ManifestDevice } from '../lib/manifest.js';
import {
  checkReady,
  ensureRecording,
  getRecording,
  recordObject,
  type RecordingItem,
  type ReportItem,
} from '../lib/recordings.js';
import { config, ddb, keys, s3, segmentFileName, segmentKey } from '../lib/store.js';
import { DEVICE_TOKEN, GRANT_TOKEN, LINK_CODE, MAX_OPEN_TICKETS, hashToken, newDeviceToken } from '../lib/tokens.js';

/** Who is calling. With a grant token, [accountId] is the account that
 *  issued it (Main's), not the phone's own. */
export interface DeviceContext {
  accountId: string;
  deviceId: string;
  /** Set for a recording grant: the only game it may upload to. */
  grantGameId?: string;
}

const GRANT_ROUTES = new Set([
  'PUT /games/{gameId}/recordings/{recordingId}/report',
  'POST /uploads',
  'POST /uploads/complete',
]);

/** A grant only reaches its own game. */
function checkGame(ctx: DeviceContext, gameId: string) {
  if (ctx.grantGameId && ctx.grantGameId !== gameId) throw forbidden('This recording grant is for another game.');
}

type DeviceEvent = APIGatewayProxyEventV2WithLambdaAuthorizer<DeviceContext>;

const MAX_FILE_BYTES = 50 * 1024 ** 3;

export const handler = (event: APIGatewayProxyEventV2 | DeviceEvent): Promise<Result> =>
  respond(async () => {
    if (event.routeKey === 'POST /devices/link') return link(body(event));
    // The ticket is the credential, as the code is for linking.
    if (event.routeKey === 'POST /grants/redeem') return redeem(body(event), event);
    if (event.routeKey === 'POST /grants/lookup') {
      // From the website's /grant page; the ticket is in the body, not the
      // path, so it stays out of access logs.
      return json(200, await lookupGameTicket(str(body(event), 'ticket', GRANT_TOKEN), event.requestContext.domainName));
    }

    const ctx = (event as DeviceEvent).requestContext.authorizer?.lambda;
    if (!ctx?.accountId || !ctx.deviceId) throw new ApiError(401, 'unauthorized', 'Device token required.');
    if (ctx.grantGameId) {
      if (!GRANT_ROUTES.has(event.routeKey)) {
        throw forbidden("A recording grant can only upload this phone's own segments.");
      }
    } else {
      await touch(ctx); // a grant's phone is not on this account's Devices page
    }
    switch (event.routeKey) {
      case 'PUT /games/{gameId}/recordings/{recordingId}/manifest':
        return putManifest(ctx, event);
      case 'PUT /games/{gameId}/recordings/{recordingId}/report':
        return putReport(ctx, event);
      case 'POST /uploads':
        return startUpload(ctx, body(event));
      case 'POST /uploads/complete':
        return completeUpload(ctx, body(event));
      case 'POST /games/{gameId}/grants':
        return postGrant(ctx, event);
      case 'POST /grant-tickets':
        return postTickets(ctx, event);
      case 'POST /devices/unlink':
        // The phone leaves its account, e.g. to join another one.
        await unlinkDevice(ctx.accountId, ctx.deviceId);
        return json(204);
      default:
        throw notFound(`No route ${event.routeKey}.`);
    }
  });

/** Records when the phone was last heard from, for the Devices page. */
async function touch(ctx: DeviceContext) {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.device(ctx.accountId, ctx.deviceId),
        UpdateExpression: 'SET lastSeenAt = :now',
        ConditionExpression: 'attribute_exists(pk)',
        ExpressionAttributeValues: { ':now': new Date().toISOString() },
      }),
    );
  } catch (e) {
    console.warn('could not update lastSeenAt', e);
  }
}

// --- Linking ----------------------------------------------------------------

interface LinkCodeItem {
  accountId: string;
  /** Absent on codes made before the website saved it. */
  email?: string;
  expiresAtMs: number;
  usedAt?: string;
}

async function link(b: Record<string, unknown>) {
  const code = str(b, 'code', LINK_CODE);
  const deviceId = str(b, 'deviceId', UUID);
  const platform = str(b, 'platform', /^(ios|android)$/);
  const model = str(b, 'model', undefined, 100);
  const now = Date.now();

  const c = (await ddb.send(new GetCommand({ TableName: config.table, Key: keys.linkCode(code) }))).Item as
    | LinkCodeItem
    | undefined;
  if (!c) throw notFound('That link code does not exist. Create a new one on the website.');
  if (c.usedAt || c.expiresAtMs < now) throw gone('That link code has expired or was already used.');
  const acct = c.accountId;
  if (await isClosed(acct)) throw gone('That account was deleted.');

  const owner = (await ddb.send(new GetCommand({ TableName: config.table, Key: keys.owner(deviceId) }))).Item as
    | { accountId: string }
    | undefined;
  if (owner && owner.accountId !== acct) {
    throw conflict('This phone is linked to another account. Unlink it there first.');
  }
  const existing = (await ddb.send(new GetCommand({ TableName: config.table, Key: keys.device(acct, deviceId) })))
    .Item as { tokenHash?: string; linkedAt?: string } | undefined;

  const token = newDeviceToken();
  const tokenHash = hashToken(token);
  const nowIso = new Date(now).toISOString();
  try {
    await ddb.send(
      new TransactWriteCommand({
        TransactItems: [
          {
            Update: {
              TableName: config.table,
              Key: keys.linkCode(code),
              UpdateExpression: 'SET usedAt = :now, deviceId = :d',
              ConditionExpression: 'attribute_not_exists(usedAt) AND expiresAtMs > :nowMs',
              ExpressionAttributeValues: { ':now': nowIso, ':d': deviceId, ':nowMs': now },
            },
          },
          {
            Put: {
              TableName: config.table,
              Item: { ...keys.owner(deviceId), accountId: acct },
              ConditionExpression: 'attribute_not_exists(pk) OR accountId = :acct',
              ExpressionAttributeValues: { ':acct': acct },
            },
          },
          {
            Put: {
              TableName: config.table,
              Item: {
                ...keys.device(acct, deviceId),
                deviceId,
                platform,
                model,
                linkedAt: existing?.linkedAt ?? nowIso,
                lastSeenAt: nowIso,
                tokenHash,
              },
            },
          },
          { Put: { TableName: config.table, Item: { ...keys.token(tokenHash), accountId: acct, deviceId } } },
          ...(existing?.tokenHash
            ? [{ Delete: { TableName: config.table, Key: keys.token(existing.tokenHash) } }]
            : []),
        ],
      }),
    );
  } catch (e) {
    if (e instanceof TransactionCanceledException) {
      const [codeCheck, ownerCheck] = e.CancellationReasons ?? [];
      if (codeCheck?.Code === 'ConditionalCheckFailed') throw gone('That link code has expired or was already used.');
      if (ownerCheck?.Code === 'ConditionalCheckFailed') {
        throw conflict('This phone is linked to another account. Unlink it there first.');
      }
    }
    throw e;
  }
  return json(200, { deviceToken: token, accountId: acct, email: c.email ?? null });
}

// --- Recording grants -------------------------------------------------------

/** Main lets its Secondary upload into this account for this game. */
async function postGrant(ctx: DeviceContext, event: APIGatewayProxyEventV2) {
  const gameId = str({ v: pathParam(event, 'gameId') }, 'v', UUID);
  const deviceId = str(body(event), 'deviceId', UUID);
  if (deviceId === ctx.deviceId) throw badRequest('A phone does not need a grant for itself.');
  return json(
    201,
    await createGrant({
      accountId: ctx.accountId,
      gameId,
      deviceId,
      issuedBy: ctx.deviceId,
      apiDomain: event.requestContext.domainName,
    }),
  );
}

/** Main keeps a few unbound tickets for pairings without signal. */
async function postTickets(ctx: DeviceContext, event: APIGatewayProxyEventV2) {
  const count = int(body(event), 'count', 1, MAX_OPEN_TICKETS);
  return json(
    201,
    await createTickets({
      accountId: ctx.accountId,
      issuedBy: ctx.deviceId,
      count,
      apiDomain: event.requestContext.domainName,
    }),
  );
}

/** Binds a ticket to one game and phone (either phone may ask). A phone
 *  linked to the ticket's account also sends its device token: the route
 *  has no authorizer, so it is looked up here. */
async function redeem(b: Record<string, unknown>, event: APIGatewayProxyEventV2) {
  return json(
    200,
    await redeemTicket({
      ticket: str(b, 'ticket', GRANT_TOKEN),
      gameId: str(b, 'gameId', UUID),
      deviceId: str(b, 'deviceId', UUID),
      apiDomain: event.requestContext.domainName,
      callerAccountId: await deviceTokenAccount(event),
    }),
  );
}

async function deviceTokenAccount(event: APIGatewayProxyEventV2) {
  const header = event.headers?.authorization ?? event.headers?.Authorization ?? '';
  const token = /^Bearer (\S+)$/.exec(header)?.[1];
  if (!token || !DEVICE_TOKEN.test(token)) return undefined;
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.token(hashToken(token)) }));
  const item = r.Item as { kind?: string; accountId?: string } | undefined;
  return item && item.kind !== 'grant' ? item.accountId : undefined;
}

// --- Manifest ---------------------------------------------------------------

async function putManifest(ctx: DeviceContext, event: APIGatewayProxyEventV2) {
  const gameId = pathParam(event, 'gameId');
  const recordingId = pathParam(event, 'recordingId');
  const raw = body(event);
  const manifest = parseManifest(raw, { gameId, recordingId, callerDeviceId: ctx.deviceId });

  // Every phone must be linked to this account or hold a grant for this game.
  for (const d of manifest.devices) {
    const linked = await ddb.send(
      new GetCommand({ TableName: config.table, Key: keys.device(ctx.accountId, d.deviceId) }),
    );
    if (!linked.Item && !(d.deviceId !== ctx.deviceId && (await getGrant(ctx.accountId, gameId, d.deviceId)))) {
      throw forbidden(
        `The ${d.role} phone (${d.model}, ${d.deviceId}) is not linked to this account and has no grant for this game.`,
      );
    }
  }

  const text = JSON.stringify(raw);
  const sha = createHash('sha256').update(text).digest('hex');
  const existing = await getRecording(ctx.accountId, gameId, recordingId);
  if (existing?.status === 'ready' && existing.manifestSha256 !== sha) {
    throw conflict('This recording is already complete with a different manifest.');
  }

  await ensureRecording(ctx.accountId, gameId, recordingId);
  // Re-sending the same manifest for a ready recording must not demote it.
  // The merged manifest goes to S3 when the recording becomes ready.
  const alreadyReady = existing?.status === 'ready';
  await ddb.send(
    new UpdateCommand({
      TableName: config.table,
      Key: keys.recording(ctx.accountId, gameId, recordingId),
      UpdateExpression: alreadyReady
        ? 'SET manifest = :m, manifestSha256 = :sha'
        : 'SET manifest = :m, manifestSha256 = :sha, #s = :uploading',
      ExpressionAttributeNames: alreadyReady ? undefined : { '#s': 'status' },
      ExpressionAttributeValues: {
        ':m': manifest,
        ':sha': sha,
        ...(alreadyReady ? {} : { ':uploading': 'uploading' }),
      },
    }),
  );
  return json(200, await checkReady(ctx.accountId, gameId, recordingId));
}

// --- Device report ----------------------------------------------------------

/** A phone's own segment list for a recording, sent from wherever it reaches
 *  the internet; Main's manifest may not have it. */
async function putReport(ctx: DeviceContext, event: APIGatewayProxyEventV2) {
  const gameId = str({ v: pathParam(event, 'gameId') }, 'v', UUID);
  const recordingId = str({ v: pathParam(event, 'recordingId') }, 'v', UUID);
  checkGame(ctx, gameId);
  const raw = body(event);
  const device = parseReport(raw, { callerDeviceId: ctx.deviceId });
  const sha = createHash('sha256').update(JSON.stringify(raw)).digest('hex');

  const key = keys.report(ctx.accountId, gameId, recordingId, ctx.deviceId);
  const [existing, previous] = await Promise.all([
    getRecording(ctx.accountId, gameId, recordingId),
    ddb.send(new GetCommand({ TableName: config.table, Key: key })),
  ]);
  const reopen = existing?.status === 'ready' && !previous.Item && isLateSecondary(existing, device);
  if (existing?.status === 'ready' && !reopen && (previous.Item as ReportItem | undefined)?.sha256 !== sha) {
    throw conflict('This recording is already complete with a different segment list.');
  }
  await ensureRecording(ctx.accountId, gameId, recordingId);
  await ddb.send(
    new PutCommand({
      TableName: config.table,
      Item: {
        ...key,
        gameId,
        recordingId,
        deviceId: ctx.deviceId,
        device,
        sha256: sha,
        reportedAt: new Date().toISOString(),
      },
    }),
  );
  if (reopen) {
    // It is ready again, with a second RecordingReady, once that phone's
    // files are in.
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.recording(ctx.accountId, gameId, recordingId),
        UpdateExpression: 'SET #s = :uploading REMOVE readyAt',
        ConditionExpression: '#s = :ready',
        ExpressionAttributeNames: { '#s': 'status' },
        ExpressionAttributeValues: { ':uploading': 'uploading', ':ready': 'ready' },
      }),
    );
  }
  return json(200, await checkReady(ctx.accountId, gameId, recordingId));
}

/** A Secondary reporting for the first time on a recording that became
 *  ready without it: Main's manifest left it out (no grant at the field). */
function isLateSecondary(rec: RecordingItem, device: ManifestDevice) {
  return (
    device.role === 'secondary' &&
    rec.manifest !== undefined &&
    !rec.manifest.devices.some((d) => d.role === 'secondary' || d.deviceId === device.deviceId)
  );
}

// --- Multipart upload -------------------------------------------------------

interface UploadItem {
  uploadId: string;
  bytes: number;
  sha256: string;
}

function uploadTarget(ctx: DeviceContext, b: Record<string, unknown>) {
  const gameId = str(b, 'gameId', UUID);
  checkGame(ctx, gameId);
  const recordingId = str(b, 'recordingId', UUID);
  const fileName = str(b, 'fileName', segmentFileName(ctx.deviceId));
  return {
    gameId,
    recordingId,
    fileName,
    key: segmentKey(ctx.accountId, gameId, recordingId, ctx.deviceId, fileName),
    itemKey: keys.upload(ctx.accountId, gameId, recordingId, fileName),
  };
}

async function headSize(key: string): Promise<number | null> {
  try {
    const h = await s3.send(new HeadObjectCommand({ Bucket: config.bucket, Key: key }));
    return h.ContentLength ?? null;
  } catch (e) {
    if (e instanceof NotFound || (e as { name?: string }).name === 'NotFound') return null;
    throw e;
  }
}

async function listAllParts(key: string, uploadId: string): Promise<Part[]> {
  const parts: Part[] = [];
  let marker: string | undefined;
  for (;;) {
    const r = await s3.send(
      new ListPartsCommand({ Bucket: config.bucket, Key: key, UploadId: uploadId, PartNumberMarker: marker }),
    );
    parts.push(...(r.Parts ?? []));
    if (!r.IsTruncated) return parts;
    marker = r.NextPartNumberMarker;
  }
}

async function startUpload(ctx: DeviceContext, b: Record<string, unknown>) {
  const t = uploadTarget(ctx, b);
  const bytes = int(b, 'bytes', 1, MAX_FILE_BYTES);
  const sha256 = str(b, 'sha256', SHA256_HEX);

  const size = await headSize(t.key);
  if (size === bytes) {
    // Already there; make sure it's counted (the S3 event may have been missed).
    await recordObject({ ...ctx, gameId: t.gameId, recordingId: t.recordingId, fileName: t.fileName, bytes });
    return json(200, { alreadyUploaded: true });
  }

  await ensureRecording(ctx.accountId, t.gameId, t.recordingId);
  const item = (await ddb.send(new GetCommand({ TableName: config.table, Key: t.itemKey }))).Item as
    | UploadItem
    | undefined;

  let uploadId: string | undefined;
  let completed: Part[] = [];
  if (item && item.bytes === bytes && item.sha256 === sha256) {
    try {
      completed = await listAllParts(t.key, item.uploadId);
      uploadId = item.uploadId;
    } catch (e) {
      if (!(e instanceof NoSuchUpload) && (e as { name?: string }).name !== 'NoSuchUpload') throw e;
    }
  } else if (item) {
    // The phone's file changed (re-recorded?): start over.
    await s3
      .send(new AbortMultipartUploadCommand({ Bucket: config.bucket, Key: t.key, UploadId: item.uploadId }))
      .catch(() => undefined);
  }

  if (!uploadId) {
    const created = await s3.send(
      new CreateMultipartUploadCommand({
        Bucket: config.bucket,
        Key: t.key,
        ContentType: 'video/mp4',
        Metadata: { sha256 },
      }),
    );
    uploadId = created.UploadId!;
    await ddb.send(
      new PutCommand({
        TableName: config.table,
        Item: {
          ...t.itemKey,
          uploadId,
          bytes,
          sha256,
          createdAt: new Date().toISOString(),
          ttl: Math.ceil(Date.now() / 1000) + 8 * 24 * 3600,
        },
      }),
    );
  }

  const partSize = config.partSizeBytes;
  const partCount = Math.ceil(bytes / partSize);
  const done = new Set(completed.map((p) => p.PartNumber));
  const expiresIn = config.urlTtlSeconds;
  const parts = await Promise.all(
    Array.from({ length: partCount }, (_, i) => i + 1)
      .filter((n) => !done.has(n))
      .map(async (partNumber) => ({
        partNumber,
        url: await getSignedUrl(
          s3,
          new UploadPartCommand({ Bucket: config.bucket, Key: t.key, UploadId: uploadId, PartNumber: partNumber }),
          { expiresIn },
        ),
      })),
  );
  return json(200, {
    uploadId,
    partSizeBytes: partSize,
    parts,
    completedParts: completed
      .filter((p) => p.PartNumber && p.ETag)
      .map((p) => ({ partNumber: p.PartNumber!, etag: p.ETag! })),
    urlsExpireAt: new Date(Date.now() + expiresIn * 1000).toISOString(),
  });
}

async function completeUpload(ctx: DeviceContext, b: Record<string, unknown>) {
  const t = uploadTarget(ctx, b);
  const uploadId = str(b, 'uploadId', undefined, 1024);
  await refuseDeleted(ctx.accountId, t.gameId, t.recordingId);
  const item = (await ddb.send(new GetCommand({ TableName: config.table, Key: t.itemKey }))).Item as
    | UploadItem
    | undefined;
  if (!item || item.uploadId !== uploadId) throw notFound('No such upload in progress. Start it again.');

  const partCount = Math.ceil(item.bytes / config.partSizeBytes);
  const rawParts = b.parts;
  if (!Array.isArray(rawParts) || rawParts.length !== partCount) {
    throw badRequest(`"parts" must list all ${partCount} parts.`);
  }
  const parts = rawParts.map((p, i) => {
    const o = (typeof p === 'object' && p !== null ? p : {}) as Record<string, unknown>;
    const partNumber = int(o, 'partNumber', 1, partCount);
    if (partNumber !== i + 1) throw badRequest('"parts" must be in order, starting at 1.');
    return { PartNumber: partNumber, ETag: str(o, 'etag', undefined, 200) };
  });

  try {
    await s3.send(
      new CompleteMultipartUploadCommand({
        Bucket: config.bucket,
        Key: t.key,
        UploadId: uploadId,
        MultipartUpload: { Parts: parts },
      }),
    );
  } catch (e) {
    const name = (e as { name?: string }).name;
    if (name === 'InvalidPart' || name === 'InvalidPartOrder' || name === 'EntityTooSmall') {
      throw badRequest(`S3 rejected the parts (${name}). Start the upload again.`);
    }
    throw e;
  }
  await ddb.send(new DeleteCommand({ TableName: config.table, Key: t.itemKey }));
  await recordObject({ ...ctx, gameId: t.gameId, recordingId: t.recordingId, fileName: t.fileName, bytes: item.bytes });
  return json(200, { ok: true });
}
