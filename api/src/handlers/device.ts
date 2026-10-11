// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Routes for phones: linking (code as credential) and, with a device
 *  token, manifest upload and multipart segment upload. */

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
  PutObjectCommand,
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
import { expectedDevices, parseManifest } from '../lib/manifest.js';
import { checkReady, ensureRecording, getRecording, recordObject } from '../lib/recordings.js';
import { config, ddb, keys, manifestKey, s3, segmentFileName, segmentKey } from '../lib/store.js';
import { LINK_CODE, hashToken, newDeviceToken } from '../lib/tokens.js';

export interface DeviceContext {
  accountId: string;
  deviceId: string;
}

type DeviceEvent = APIGatewayProxyEventV2WithLambdaAuthorizer<DeviceContext>;

const MAX_FILE_BYTES = 50 * 1024 ** 3;

export const handler = (event: APIGatewayProxyEventV2 | DeviceEvent): Promise<Result> =>
  respond(async () => {
    if (event.routeKey === 'POST /devices/link') return link(body(event));

    const ctx = (event as DeviceEvent).requestContext.authorizer?.lambda;
    if (!ctx?.accountId || !ctx.deviceId) throw new ApiError(401, 'unauthorized', 'Device token required.');
    await touch(ctx);
    switch (event.routeKey) {
      case 'PUT /games/{gameId}/recordings/{recordingId}/manifest':
        return putManifest(ctx, event);
      case 'POST /uploads':
        return startUpload(ctx, body(event));
      case 'POST /uploads/complete':
        return completeUpload(ctx, body(event));
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
  return json(200, { deviceToken: token, accountId: acct });
}

// --- Manifest ---------------------------------------------------------------

async function putManifest(ctx: DeviceContext, event: APIGatewayProxyEventV2) {
  const gameId = pathParam(event, 'gameId');
  const recordingId = pathParam(event, 'recordingId');
  const raw = body(event);
  const manifest = parseManifest(raw, { gameId, recordingId, callerDeviceId: ctx.deviceId });

  for (const d of manifest.devices) {
    const linked = await ddb.send(
      new GetCommand({ TableName: config.table, Key: keys.device(ctx.accountId, d.deviceId) }),
    );
    if (!linked.Item) {
      throw forbidden(`The ${d.role} phone (${d.model}, ${d.deviceId}) is not linked to this account.`);
    }
  }

  const text = JSON.stringify(raw);
  const sha = createHash('sha256').update(text).digest('hex');
  const existing = await getRecording(ctx.accountId, gameId, recordingId);
  if (existing?.status === 'ready' && existing.manifestSha256 !== sha) {
    throw conflict('This recording is already complete with a different manifest.');
  }

  await s3.send(
    new PutObjectCommand({
      Bucket: config.bucket,
      Key: manifestKey(ctx.accountId, gameId, recordingId),
      Body: text,
      ContentType: 'application/json',
    }),
  );
  await ensureRecording(ctx.accountId, gameId, recordingId);
  // Re-sending the same manifest for a ready recording must not demote it.
  const alreadyReady = existing?.status === 'ready';
  await ddb.send(
    new UpdateCommand({
      TableName: config.table,
      Key: keys.recording(ctx.accountId, gameId, recordingId),
      UpdateExpression: alreadyReady
        ? 'SET expected = :e, manifestSha256 = :sha'
        : 'SET expected = :e, manifestSha256 = :sha, #s = :uploading',
      ExpressionAttributeNames: alreadyReady ? undefined : { '#s': 'status' },
      ExpressionAttributeValues: {
        ':e': expectedDevices(manifest),
        ':sha': sha,
        ...(alreadyReady ? {} : { ':uploading': 'uploading' }),
      },
    }),
  );
  return json(200, await checkReady(ctx.accountId, gameId, recordingId));
}

// --- Multipart upload -------------------------------------------------------

interface UploadItem {
  uploadId: string;
  bytes: number;
  sha256: string;
}

function uploadTarget(ctx: DeviceContext, b: Record<string, unknown>) {
  const gameId = str(b, 'gameId', UUID);
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
