// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Contributions: results a user agreed to share to improve the models
 * (a pitch map, kit groups, ball labels, must-see moments), made by the
 * processing engine on their own computer (`engine.py share`) and uploaded
 * by the Mac app. Kept apart from footage: their own bucket, their own
 * retention, not deleted with the game they came from (the privacy policy
 * says so), deleted when the user withdraws them or closes the account.
 *
 * Flow: `POST /contributions` with the engine's contribution file
 * (shared/schemas/engine-contribution.schema.json) and the consent wording
 * the user agreed to; the server checks the recording is theirs, records
 * the contribution as `uploading` and returns a signed PUT per file (S3
 * checks each file's SHA-256 on arrival). `POST /contributions/{id}/complete`
 * checks every file arrived with its size and checksum, stores the
 * contribution file beside them, marks it `complete` and publishes
 * `ContributionReady`.
 *
 * S3 (the contributions bucket): `contributions/<accountId>/<contributionId>/`
 *   `contribution.json`  the engine's file plus the consent and ids
 *   `files/<path>`       each listed file, at the engine's relative path
 */

import { PutEventsCommand } from '@aws-sdk/client-eventbridge';
import { GetObjectCommand, HeadObjectCommand, NotFound, PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { DeleteCommand, GetCommand, PutCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { randomUUID } from 'node:crypto';
import { Ajv2020 } from 'ajv/dist/2020.js';
import schema from '../../../shared/schemas/engine-contribution.schema.json' with { type: 'json' };
import { ApiError, badRequest, notFound, str, UUID } from './http.js';
import { deletePrefix } from './deletion.js';
import { config, ddb, events, keys, queryPrefix, s3 } from './store.js';

/** Consent wordings the apps may show (shared/consent/<version>.md). A new
 *  wording gets a new version; contributions keep the version agreed to. */
export const CONSENT_VERSIONS = ['share-v1'] as const;

export const LIMITS = {
  files: 2000,
  fileBytes: 50 * 1024 * 1024,
  totalBytes: 500 * 1024 * 1024,
  pathLength: 300,
};

/** Relative paths of plain names (no `..`, no hidden or empty parts, no
 *  leading or trailing `/`): the engine's own layout (pitch/background.png,
 *  engine/labels/ball-1/images/x.jpg). */
const PATH = /^[A-Za-z0-9_][A-Za-z0-9._-]*(\/[A-Za-z0-9_][A-Za-z0-9._-]*)*$/;
const SHA256_HEX = /^[0-9a-f]{64}$/;

const ajv = new Ajv2020({ allErrors: true, strict: false });
const validate = ajv.compile(schema);

export type ContributionStatus = 'uploading' | 'complete';

export interface ContributionItem {
  pk: string;
  sk: string;
  contributionId: string;
  gameId: string;
  recordingId: string;
  kind: string;
  name: string;
  engineVersion: string;
  consentVersion: string;
  status: ContributionStatus;
  files: number;
  bytes: number;
  createdAt: string;
  completedAt?: string;
}

interface FileEntry {
  path: string;
  bytes: number;
  sha256: string;
}

export const contributionPrefix = (acct: string, id: string) => `contributions/${acct}/${id}/`;
export const contributionsAccountPrefix = (acct: string) => `contributions/${acct}/`;
export const fileKey = (acct: string, id: string, path: string) => `${contributionPrefix(acct, id)}files/${path}`;
const docKey = (acct: string, id: string) => `${contributionPrefix(acct, id)}contribution.json`;
const b64 = (hex: string) => Buffer.from(hex, 'hex').toString('base64');

function checkFiles(files: FileEntry[]) {
  if (files.length === 0) throw badRequest('A contribution needs at least one file.');
  if (files.length > LIMITS.files) throw badRequest(`At most ${LIMITS.files} files in one contribution.`);
  const seen = new Set<string>();
  let total = 0;
  for (const f of files) {
    if (typeof f.path !== 'string' || f.path.length > LIMITS.pathLength || !PATH.test(f.path)) {
      throw badRequest(`File path "${String(f.path).slice(0, 80)}" is not allowed (relative, no "..").`);
    }
    if (seen.has(f.path)) throw badRequest(`File ${f.path} is listed twice.`);
    seen.add(f.path);
    if (!Number.isInteger(f.bytes) || f.bytes < 0 || f.bytes > LIMITS.fileBytes) {
      throw badRequest(`File ${f.path}: "bytes" must be an integer up to ${LIMITS.fileBytes}.`);
    }
    if (typeof f.sha256 !== 'string' || !SHA256_HEX.test(f.sha256)) {
      throw badRequest(`File ${f.path}: "sha256" must be 64 lowercase hex digits.`);
    }
    total += f.bytes;
  }
  if (total > LIMITS.totalBytes) throw badRequest(`At most ${LIMITS.totalBytes} bytes in one contribution.`);
  return total;
}

/** POST /contributions */
export async function createContribution(acct: string, body: Record<string, unknown>) {
  const gameId = str(body, 'gameId', UUID);
  const recordingId = str(body, 'recordingId', UUID);
  const consentVersion = str(body, 'consentVersion');
  if (!(CONSENT_VERSIONS as readonly string[]).includes(consentVersion)) {
    throw badRequest(`"consentVersion" must be one of ${CONSENT_VERSIONS.join(', ')}.`);
  }
  const doc = body.contribution;
  if (!validate(doc)) {
    throw new ApiError(
      400,
      'invalid_contribution',
      'The contribution does not match the schema.',
      (validate.errors ?? []).map((e) => `${e.instancePath || '/'} ${e.message ?? ''}`.trim()),
    );
  }
  const c = doc as { kind: string; name: string; engine: { version: string }; files: FileEntry[]; recording: { gameId?: string } };
  if (c.recording.gameId && c.recording.gameId !== gameId) {
    throw badRequest('The contribution is from another game than "gameId".');
  }
  const total = checkFiles(c.files);
  const rec = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.recording(acct, gameId, recordingId) }));
  if (!rec.Item) throw notFound('No such recording on this account.');

  const id = randomUUID();
  const now = new Date().toISOString();
  const item: ContributionItem = {
    ...keys.contribution(acct, id),
    contributionId: id,
    gameId,
    recordingId,
    kind: c.kind,
    name: String(c.name).slice(0, 100),
    engineVersion: String(c.engine.version).slice(0, 100),
    consentVersion,
    status: 'uploading',
    files: c.files.length,
    bytes: total,
    createdAt: now,
  };
  await ddb.send(new PutCommand({ TableName: config.table, Item: item }));
  // The contribution file goes in now (the files' list is the upload's
  // checklist); complete adds the completion time to the stored copy.
  await s3.send(
    new PutObjectCommand({
      Bucket: config.contributionsBucket,
      Key: docKey(acct, id),
      ContentType: 'application/json',
      Body: JSON.stringify({ ...publicView(item), contribution: doc }),
    }),
  );
  const expiresAt = new Date(Date.now() + config.urlTtlSeconds * 1000).toISOString();
  const uploads = await Promise.all(
    c.files.map(async (f) => ({
      path: f.path,
      url: await getSignedUrl(
        s3,
        new PutObjectCommand({
          Bucket: config.contributionsBucket,
          Key: fileKey(acct, id, f.path),
          ContentLength: f.bytes,
          ChecksumSHA256: b64(f.sha256),
        }),
        { expiresIn: config.urlTtlSeconds, unhoistableHeaders: new Set(['x-amz-checksum-sha256']) },
      ),
      // Sent with the PUT: S3 refuses a body whose SHA-256 differs.
      headers: { 'x-amz-checksum-sha256': b64(f.sha256), 'content-length': String(f.bytes) },
    })),
  );
  return { ...publicView(item), expiresAt, uploads };
}

async function getItem(acct: string, id: string): Promise<ContributionItem> {
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.contribution(acct, id) }));
  if (!r.Item) throw notFound('No such contribution on this account.');
  return r.Item as ContributionItem;
}

/** POST /contributions/{contributionId}/complete */
export async function completeContribution(acct: string, id: string) {
  const item = await getItem(acct, id);
  if (item.status === 'complete') return publicView(item);
  const got = await s3.send(new GetObjectCommand({ Bucket: config.contributionsBucket, Key: docKey(acct, id) }));
  const stored = JSON.parse(await got.Body!.transformToString()) as { contribution: { files: FileEntry[] } };
  const missing: string[] = [];
  for (const f of stored.contribution.files) {
    try {
      const h = await s3.send(
        new HeadObjectCommand({ Bucket: config.contributionsBucket, Key: fileKey(acct, id, f.path), ChecksumMode: 'ENABLED' }),
      );
      if (h.ContentLength !== f.bytes || (h.ChecksumSHA256 && h.ChecksumSHA256 !== b64(f.sha256))) missing.push(f.path);
    } catch (e) {
      if (e instanceof NotFound || (e as { name?: string }).name === 'NotFound') missing.push(f.path);
      else throw e;
    }
  }
  if (missing.length) {
    throw new ApiError(409, 'conflict', `${missing.length} file(s) have not arrived (or differ).`, { missing: missing.slice(0, 50) });
  }
  const completedAt = new Date().toISOString();
  await ddb.send(
    new UpdateCommand({
      TableName: config.table,
      Key: keys.contribution(acct, id),
      UpdateExpression: 'SET #s = :c, completedAt = :t',
      ExpressionAttributeNames: { '#s': 'status' },
      ExpressionAttributeValues: { ':c': 'complete', ':t': completedAt },
    }),
  );
  const done: ContributionItem = { ...item, status: 'complete', completedAt };
  await s3.send(
    new PutObjectCommand({
      Bucket: config.contributionsBucket,
      Key: docKey(acct, id),
      ContentType: 'application/json',
      Body: JSON.stringify({ ...publicView(done), contribution: stored.contribution }),
    }),
  );
  const r = await events.send(
    new PutEventsCommand({
      Entries: [
        {
          EventBusName: config.eventBus,
          Source: 'opensportsball',
          DetailType: 'ContributionReady',
          Detail: JSON.stringify({
            accountId: acct,
            contributionId: id,
            kind: item.kind,
            bucket: config.contributionsBucket,
            prefix: contributionPrefix(acct, id),
          }),
        },
      ],
    }),
  );
  if (r.FailedEntryCount) throw new Error(`ContributionReady event rejected: ${JSON.stringify(r.Entries)}`);
  return publicView(done);
}

/** GET /contributions */
export async function listContributions(acct: string) {
  const items = await queryPrefix<ContributionItem>(acct, 'CONTRIB#');
  items.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return { contributions: items.map(publicView) };
}

/** DELETE /contributions/{contributionId}: withdraws it, for good. */
export async function deleteContribution(acct: string, id: string) {
  await getItem(acct, id);
  await deletePrefix(config.contributionsBucket, contributionPrefix(acct, id));
  await ddb.send(new DeleteCommand({ TableName: config.table, Key: keys.contribution(acct, id) }));
}

/** Every contribution of an account (deleting the account). */
export async function deleteAllContributions(acct: string) {
  if (!config.contributionsBucketOrNull) return;
  await deletePrefix(config.contributionsBucketOrNull, contributionsAccountPrefix(acct));
}

function publicView(i: ContributionItem) {
  return {
    contributionId: i.contributionId,
    gameId: i.gameId,
    recordingId: i.recordingId,
    kind: i.kind,
    name: i.name,
    engineVersion: i.engineVersion,
    consentVersion: i.consentVersion,
    status: i.status,
    files: i.files,
    bytes: i.bytes,
    createdAt: i.createdAt,
    completedAt: i.completedAt ?? null,
  };
}
