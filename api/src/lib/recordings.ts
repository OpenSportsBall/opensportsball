// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Recording state: which files have arrived, and the one-time switch to
 *  `ready` that hands the recording to processing. */

import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import { PutEventsCommand } from '@aws-sdk/client-eventbridge';
import { PutObjectCommand } from '@aws-sdk/client-s3';
import { GetCommand, PutCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { expectedDevices, mergeManifest, type ExpectedDevice, type Manifest, type ManifestDevice } from './manifest.js';
import { refuseDeleted } from './deletion.js';
import { supersedeActiveJob } from './jobs.js';
import { config, ddb, events, keys, manifestKey, queryPrefix, recordingPrefix, s3 } from './store.js';

export type RecordingStatus = 'waiting_for_manifest' | 'uploading' | 'ready';

export const STATUS_ORDER: RecordingStatus[] = ['waiting_for_manifest', 'uploading', 'ready'];

export interface RecordingItem {
  pk: string;
  sk: string;
  gameId: string;
  recordingId: string;
  createdAt: string;
  status: RecordingStatus;
  /** Main's manifest as uploaded (may lack the Secondary's segments). */
  manifest?: Manifest;
  manifestSha256?: string;
  /** When it last became ready; removed while a late Secondary uploads. */
  readyAt?: string;
  /** The job processing it, or the last one that did (lib/jobs.ts). */
  activeJobId?: string;
}

export interface ReportItem {
  sk: string;
  gameId: string;
  recordingId: string;
  deviceId: string;
  device: ManifestDevice;
  sha256: string;
  reportedAt: string;
}

export interface ObjectItem {
  sk: string;
  gameId: string;
  recordingId: string;
  deviceId: string;
  fileName: string;
  bytes: number;
  uploadedAt: string;
}

async function putIfAbsent(item: Record<string, unknown>) {
  try {
    await ddb.send(
      new PutCommand({ TableName: config.table, Item: item, ConditionExpression: 'attribute_not_exists(pk)' }),
    );
  } catch (e) {
    if (!(e instanceof ConditionalCheckFailedException)) throw e;
  }
}

/** Games and recordings come into existence with their first upload or
 *  manifest, whichever arrives first, unless deleted on the website (410). */
export async function ensureRecording(acct: string, gameId: string, recordingId: string) {
  await refuseDeleted(acct, gameId, recordingId);
  const now = new Date().toISOString();
  await putIfAbsent({ ...keys.game(acct, gameId), gameId, createdAt: now });
  await putIfAbsent({
    ...keys.recording(acct, gameId, recordingId),
    gameId,
    recordingId,
    createdAt: now,
    status: 'waiting_for_manifest',
  });
}

export async function getRecording(acct: string, gameId: string, recordingId: string) {
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.recording(acct, gameId, recordingId) }));
  return r.Item as RecordingItem | undefined;
}

export const listReports = (acct: string, gameId: string, recordingId?: string) =>
  queryPrefix<ReportItem>(acct, recordingId ? `REPORT#${gameId}#${recordingId}#` : `REPORT#${gameId}#`);

export const reportMap = (reports: ReportItem[]) => new Map(reports.map((r) => [r.deviceId, r.device]));

/** When recording started: the earliest segment start Main's manifest or a
 *  phone's report lists, or null before either has arrived. */
export function recordedAt(rec: RecordingItem, reports: ReportItem[]): string | null {
  const starts = [...(rec.manifest?.devices ?? []), ...reports.map((r) => r.device)]
    .flatMap((d) => d.segments ?? [])
    .map((s) => s.startedAtDeviceMs);
  return starts.length ? new Date(Math.min(...starts)).toISOString() : null;
}

export const listObjects = (acct: string, gameId: string, recordingId?: string) =>
  queryPrefix<ObjectItem>(acct, recordingId ? `OBJ#${gameId}#${recordingId}#` : `OBJ#${gameId}#`);

/** Notes that a segment file is in the bucket (idempotent), then checks
 *  whether the recording is now complete. */
export async function recordObject(o: {
  accountId: string;
  gameId: string;
  recordingId: string;
  deviceId: string;
  fileName: string;
  bytes: number;
}) {
  await ensureRecording(o.accountId, o.gameId, o.recordingId);
  await ddb.send(
    new PutCommand({
      TableName: config.table,
      Item: {
        ...keys.object(o.accountId, o.gameId, o.recordingId, o.deviceId, o.fileName),
        gameId: o.gameId,
        recordingId: o.recordingId,
        deviceId: o.deviceId,
        fileName: o.fileName,
        bytes: o.bytes,
        uploadedAt: new Date().toISOString(),
      },
    }),
  );
  return checkReady(o.accountId, o.gameId, o.recordingId);
}

/** Files the manifest and reports list that are not in the bucket yet. A
 *  file only counts if its size matches what was listed. */
export function missingFiles(expected: ExpectedDevice[], objects: ObjectItem[]) {
  const have = new Map(objects.map((o) => [`${o.deviceId}/${o.fileName}`, o.bytes]));
  return expected.flatMap((d) =>
    (d.files ?? [])
      .filter((f) => have.get(`${d.deviceId}/${f.fileName}`) !== f.bytes)
      .map((f) => ({ deviceId: d.deviceId, fileName: f.fileName })),
  );
}

/** Moves the recording to `ready` exactly once when everything has
 *  arrived (Main's manifest, every phone's segment list, every file),
 *  writes the merged manifest for processing, and publishes RecordingReady.
 *  `awaitingReports` lists phones whose segments are not known yet. */
export async function checkReady(acct: string, gameId: string, recordingId: string) {
  const rec = await getRecording(acct, gameId, recordingId);
  if (!rec?.manifest) {
    return { status: 'waiting_for_manifest' as RecordingStatus, missing: [], awaitingReports: [] };
  }
  const [reports, objects] = await Promise.all([
    listReports(acct, gameId, recordingId),
    listObjects(acct, gameId, recordingId),
  ]);
  const byDevice = reportMap(reports);
  const expected = expectedDevices(rec.manifest, byDevice);
  const missing = missingFiles(expected, objects);
  const awaitingReports = expected.filter((d) => d.files === null).map((d) => d.deviceId);
  if (missing.length > 0 || awaitingReports.length > 0 || rec.status === 'ready') {
    return { status: rec.status, missing, awaitingReports };
  }

  // Before the status flips, so processing never sees a partial manifest.
  // Racing invocations write the same content.
  await s3.send(
    new PutObjectCommand({
      Bucket: config.bucket,
      Key: manifestKey(acct, gameId, recordingId),
      Body: JSON.stringify(mergeManifest(rec.manifest, byDevice)),
      ContentType: 'application/json',
    }),
  );

  try {
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.recording(acct, gameId, recordingId),
        UpdateExpression: 'SET #s = :ready, readyAt = :now',
        ConditionExpression: '#s <> :ready',
        ExpressionAttributeNames: { '#s': 'status' },
        ExpressionAttributeValues: { ':ready': 'ready', ':now': new Date().toISOString() },
      }),
    );
  } catch (e) {
    // Another invocation got there first and published the event.
    if (e instanceof ConditionalCheckFailedException) {
      return { status: 'ready' as RecordingStatus, missing, awaitingReports };
    }
    throw e;
  }

  try {
    // Ready a second time (a late Secondary): a job that started on Main's
    // footage alone is working from an old manifest.
    await supersedeActiveJob(rec);
    await publishReady(acct, gameId, recordingId);
  } catch (e) {
    // Undo so the next upload or manifest call retries the hand-off.
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.recording(acct, gameId, recordingId),
        UpdateExpression: 'SET #s = :uploading REMOVE readyAt',
        ExpressionAttributeNames: { '#s': 'status' },
        ExpressionAttributeValues: { ':uploading': 'uploading' },
      }),
    );
    throw e;
  }
  return { status: 'ready' as RecordingStatus, missing, awaitingReports };
}

async function publishReady(acct: string, gameId: string, recordingId: string) {
  const r = await events.send(
    new PutEventsCommand({
      Entries: [
        {
          EventBusName: config.eventBus,
          Source: 'opensportsball',
          DetailType: 'RecordingReady',
          Detail: JSON.stringify({
            accountId: acct,
            gameId,
            recordingId,
            bucket: config.bucket,
            prefix: recordingPrefix(acct, gameId, recordingId),
            manifestKey: manifestKey(acct, gameId, recordingId),
          }),
        },
      ],
    }),
  );
  if (r.FailedEntryCount) throw new Error(`RecordingReady event rejected: ${JSON.stringify(r.Entries)}`);
}
