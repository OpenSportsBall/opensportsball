// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Deleting a recording or a whole game from the website, for good.
 *
 *  A delete first leaves a `DELETED#` marker, then removes the footage in
 *  S3 (aborting unfinished multipart uploads) and the table items. The
 *  marker stays: a phone that still has the recording queued gets 410 Gone
 *  instead of quietly creating it again (ensureRecording). If a delete
 *  fails partway, calling it again finishes it. */

import { AbortMultipartUploadCommand, DeleteObjectsCommand, ListMultipartUploadsCommand, ListObjectsV2Command } from '@aws-sdk/client-s3';
import { BatchWriteCommand, GetCommand, PutCommand } from '@aws-sdk/lib-dynamodb';
import { gone, notFound } from './http.js';
import { config, ddb, gamePrefix, keys, queryPrefix, recordingPrefix, s3 } from './store.js';

type Key = { pk: string; sk: string };

const exists = async (key: Key) =>
  Boolean((await ddb.send(new GetCommand({ TableName: config.table, Key: key }))).Item);

/** Refuses anything for a recording, or a game, deleted on the website. */
export async function refuseDeleted(acct: string, gameId: string, recordingId: string) {
  const [game, rec] = await Promise.all([
    exists(keys.deletedGame(acct, gameId)),
    exists(keys.deletedRecording(acct, gameId, recordingId)),
  ]);
  if (game) throw gone('This game was deleted on the website.');
  if (rec) throw gone('This recording was deleted on the website.');
}

export async function deleteRecording(acct: string, gameId: string, recordingId: string) {
  const marker = keys.deletedRecording(acct, gameId, recordingId);
  const [rec, deleted] = await Promise.all([exists(keys.recording(acct, gameId, recordingId)), exists(marker)]);
  if (!rec && !deleted) throw notFound('No such recording.');
  await putMarker(marker);
  await deleteFootage(recordingPrefix(acct, gameId, recordingId));
  const sub = `${gameId}#${recordingId}#`;
  await deleteItems(acct, [`REPORT#${sub}`, `OBJ#${sub}`, `UPLOAD#${sub}`]);
  await deleteKeys([keys.recording(acct, gameId, recordingId)]);
}

interface GrantRef {
  sk: string;
  gameId?: string;
  tokenHash: string;
}

export async function deleteGame(acct: string, gameId: string) {
  const marker = keys.deletedGame(acct, gameId);
  const [game, deleted] = await Promise.all([exists(keys.game(acct, gameId)), exists(marker)]);
  if (!game && !deleted) throw notFound('No such game.');
  await putMarker(marker);
  await deleteFootage(gamePrefix(acct, gameId));

  // Website tickets for this game that no phone has redeemed yet. Grant
  // tokens already in a phone's hands are left to expire, so that phone
  // hears the game is gone (410) rather than that it was signed out (401).
  const tickets = (await queryPrefix<GrantRef>(acct, 'TICKET#')).filter((t) => t.gameId === gameId);
  await deleteKeys(tickets.flatMap((t) => [keys.token(t.tokenHash), { pk: `ACCOUNT#${acct}`, sk: t.sk }]));

  const g = `${gameId}#`;
  // DELETED#<gameId># is each recording's marker; the game's covers them.
  await deleteItems(acct, [`GRANT#${g}`, `REPORT#${g}`, `OBJ#${g}`, `UPLOAD#${g}`, `REC#${g}`, `DELETED#${g}`]);
  await deleteKeys([keys.game(acct, gameId)]);
}

const putMarker = (key: Key) =>
  ddb.send(new PutCommand({ TableName: config.table, Item: { ...key, deletedAt: new Date().toISOString() } }));

/** Aborts unfinished uploads, then deletes every object, under [prefix]. */
async function deleteFootage(prefix: string) {
  let keyMarker: string | undefined;
  let uploadIdMarker: string | undefined;
  do {
    const r = await s3.send(
      new ListMultipartUploadsCommand({
        Bucket: config.bucket,
        Prefix: prefix,
        KeyMarker: keyMarker,
        UploadIdMarker: uploadIdMarker,
      }),
    );
    await Promise.all(
      (r.Uploads ?? []).map((u) =>
        s3.send(new AbortMultipartUploadCommand({ Bucket: config.bucket, Key: u.Key, UploadId: u.UploadId })),
      ),
    );
    [keyMarker, uploadIdMarker] = r.IsTruncated ? [r.NextKeyMarker, r.NextUploadIdMarker] : [undefined, undefined];
  } while (keyMarker);

  let token: string | undefined;
  do {
    const r = await s3.send(new ListObjectsV2Command({ Bucket: config.bucket, Prefix: prefix, ContinuationToken: token }));
    const objects = (r.Contents ?? []).map((o) => ({ Key: o.Key! }));
    if (objects.length) {
      const d = await s3.send(
        new DeleteObjectsCommand({ Bucket: config.bucket, Delete: { Objects: objects, Quiet: true } }),
      );
      if (d.Errors?.length) throw new Error(`could not delete ${d.Errors.length} objects: ${JSON.stringify(d.Errors[0])}`);
    }
    token = r.NextContinuationToken;
  } while (token);
}

async function deleteItems(acct: string, prefixes: string[]) {
  for (const prefix of prefixes) {
    const items = await queryPrefix<Key>(acct, prefix);
    await deleteKeys(items.map(({ pk, sk }) => ({ pk, sk })));
  }
}

async function deleteKeys(all: Key[]) {
  for (let i = 0; i < all.length; i += 25) {
    let requests = all.slice(i, i + 25).map((Key) => ({ DeleteRequest: { Key } }));
    for (let attempt = 0; requests.length; attempt++) {
      if (attempt > 0) await new Promise((r) => setTimeout(r, 50 * 2 ** Math.min(attempt, 6)));
      const r = await ddb.send(new BatchWriteCommand({ RequestItems: { [config.table]: requests } }));
      requests = (r.UnprocessedItems?.[config.table] ?? []) as typeof requests;
      if (attempt > 8 && requests.length) throw new Error('DynamoDB kept leaving deletes unprocessed');
    }
  }
}
