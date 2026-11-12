// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Deletes one uploaded recording, or a whole game, from the live stack:
 * its footage and manifest in S3, any unfinished multipart uploads, and
 * its DynamoDB items (see the table in src/lib/store.ts).
 *
 *   node scripts/delete-recording.ts --account <acct>
 *       lists the account's games and recordings
 *   node scripts/delete-recording.ts --game <gameId> --recording <recId>
 *       deletes one recording (REC, REPORT, OBJ, UPLOAD items + S3 prefix)
 *   node scripts/delete-recording.ts --game <gameId>
 *       deletes the whole game, including its grants and their tokens
 *
 * --account is looked up from the game when left out. Nothing is deleted
 * without --yes; without it the script prints what it would delete.
 * Table, bucket and region come from infra/cdk-outputs.json unless
 * TABLE_NAME, BUCKET_NAME or AWS_REGION are set. Run from api/ with
 * AWS credentials, e.g. AWS_PROFILE=<profile>.
 */

import { readFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  AbortMultipartUploadCommand,
  DeleteObjectsCommand,
  ListMultipartUploadsCommand,
  ListObjectsV2Command,
  S3Client,
} from '@aws-sdk/client-s3';
import { BatchWriteCommand, DynamoDBDocumentClient, QueryCommand, ScanCommand } from '@aws-sdk/lib-dynamodb';

const { values: args } = parseArgs({
  options: {
    account: { type: 'string' },
    game: { type: 'string' },
    recording: { type: 'string' },
    yes: { type: 'boolean', default: false },
  },
});

const outputs = JSON.parse(readFileSync(new URL('../../infra/cdk-outputs.json', import.meta.url), 'utf8'))
  .OpenSportsBall as Record<string, string>;
const table = process.env.TABLE_NAME ?? outputs.TableName!;
const bucket = process.env.BUCKET_NAME ?? outputs.FootageBucket!;
const region = process.env.AWS_REGION ?? outputs.UserPoolId!.split('_')[0];

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
const s3 = new S3Client({ region });

type Key = { pk: string; sk: string };

async function query(pk: string, prefix: string) {
  const items: Record<string, unknown>[] = [];
  let start: Record<string, unknown> | undefined;
  do {
    const page = await ddb.send(
      new QueryCommand({
        TableName: table,
        KeyConditionExpression: 'pk = :pk AND begins_with(sk, :prefix)',
        ExpressionAttributeValues: { ':pk': pk, ':prefix': prefix },
        ExclusiveStartKey: start,
      }),
    );
    items.push(...(page.Items ?? []));
    start = page.LastEvaluatedKey;
  } while (start);
  return items;
}

/** The account a game belongs to. Scans, so only for when --account is
 *  left out; the table is small. */
async function findAccount(gameId: string) {
  const found = new Set<string>();
  let start: Record<string, unknown> | undefined;
  do {
    const page = await ddb.send(
      new ScanCommand({
        TableName: table,
        FilterExpression: 'sk = :sk',
        ExpressionAttributeValues: { ':sk': `GAME#${gameId}` },
        ProjectionExpression: 'pk',
        ExclusiveStartKey: start,
      }),
    );
    for (const i of page.Items ?? []) found.add((i.pk as string).replace(/^ACCOUNT#/, ''));
    start = page.LastEvaluatedKey;
  } while (start);
  if (found.size === 0) throw new Error(`No game ${gameId} in ${table}.`);
  if (found.size > 1) throw new Error(`Game ${gameId} is in several accounts (${[...found]}); pass --account.`);
  return [...found][0]!;
}

async function listAccount(acct: string) {
  const pk = `ACCOUNT#${acct}`;
  const [games, recs, objs] = await Promise.all([query(pk, 'GAME#'), query(pk, 'REC#'), query(pk, 'OBJ#')]);
  if (games.length === 0) console.log(`No games in account ${acct}.`);
  for (const g of games) {
    console.log(`game ${g.gameId}  created ${g.createdAt}`);
    for (const r of recs.filter((r) => r.gameId === g.gameId)) {
      const files = objs.filter((o) => o.recordingId === r.recordingId);
      const mb = files.reduce((n, o) => n + (o.bytes as number), 0) / 1e6;
      console.log(`  recording ${r.recordingId}  ${r.status}  ${files.length} files, ${mb.toFixed(1)} MB  created ${r.createdAt}`);
    }
  }
}

async function deleteItems(keys: Key[]) {
  for (let i = 0; i < keys.length; i += 25) {
    let requests = keys.slice(i, i + 25).map((Key) => ({ DeleteRequest: { Key } }));
    while (requests.length > 0) {
      const r = await ddb.send(new BatchWriteCommand({ RequestItems: { [table]: requests } }));
      requests = (r.UnprocessedItems?.[table] ?? []) as typeof requests;
      if (requests.length > 0) await new Promise((res) => setTimeout(res, 500));
    }
  }
}

async function listObjects(prefix: string) {
  const keys: { key: string; bytes: number }[] = [];
  let token: string | undefined;
  do {
    const page = await s3.send(new ListObjectsV2Command({ Bucket: bucket, Prefix: prefix, ContinuationToken: token }));
    for (const o of page.Contents ?? []) keys.push({ key: o.Key!, bytes: o.Size ?? 0 });
    token = page.NextContinuationToken;
  } while (token);
  return keys;
}

async function listUploads(prefix: string) {
  const uploads: { key: string; uploadId: string }[] = [];
  let keyMarker: string | undefined;
  let idMarker: string | undefined;
  do {
    const page = await s3.send(
      new ListMultipartUploadsCommand({ Bucket: bucket, Prefix: prefix, KeyMarker: keyMarker, UploadIdMarker: idMarker }),
    );
    for (const u of page.Uploads ?? []) uploads.push({ key: u.Key!, uploadId: u.UploadId! });
    keyMarker = page.IsTruncated ? page.NextKeyMarker : undefined;
    idMarker = page.IsTruncated ? page.NextUploadIdMarker : undefined;
  } while (keyMarker);
  return uploads;
}

async function deleteObjects(keys: string[]) {
  for (let i = 0; i < keys.length; i += 1000) {
    const r = await s3.send(
      new DeleteObjectsCommand({
        Bucket: bucket,
        Delete: { Objects: keys.slice(i, i + 1000).map((Key) => ({ Key })), Quiet: true },
      }),
    );
    if (r.Errors?.length) throw new Error(`S3 delete failed: ${JSON.stringify(r.Errors)}`);
  }
}

async function main() {
  if (!args.game) {
    if (!args.account) throw new Error('Pass --account to list, or --game [--recording] to delete.');
    return listAccount(args.account);
  }
  const gameId = args.game;
  const recId = args.recording;
  // An empty or partial id would widen every prefix below to other games.
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  if (!uuid.test(gameId) || (recId !== undefined && !uuid.test(recId))) {
    throw new Error('--game and --recording must be full UUIDs.');
  }
  const acct = args.account ?? (await findAccount(gameId));
  const pk = `ACCOUNT#${acct}`;

  // Ids are fixed-length UUIDs, so these prefixes can't catch a neighbour.
  const scope = recId ? `${gameId}#${recId}` : gameId;
  const items = (
    await Promise.all([
      query(pk, `REC#${scope}`),
      query(pk, `REPORT#${scope}#`),
      query(pk, `OBJ#${scope}#`),
      query(pk, `UPLOAD#${scope}#`),
      query(pk, `FLINK#${scope}#`),
      ...(recId ? [] : [query(pk, `GAME#${gameId}`), query(pk, `GRANT#${gameId}#`)]),
    ])
  ).flat();
  const keys: Key[] = items.map((i) => ({ pk: i.pk as string, sk: i.sk as string }));
  // A game's grants each have a TOKEN# item that lets the other phone upload.
  for (const g of items.filter((i) => (i.sk as string).startsWith('GRANT#'))) {
    keys.push({ pk: `TOKEN#${g.tokenHash}`, sk: 'TOKEN' });
  }

  // A footage link's token is what its download page is opened with.
  for (const l of items.filter((i) => (i.sk as string).startsWith('FLINK#'))) {
    keys.push({ pk: `TOKEN#${l.linkId}`, sk: 'TOKEN' });
  }

  const prefix = `accounts/${acct}/games/${gameId}/` + (recId ? `recordings/${recId}/` : '');
  const [objects, uploads] = await Promise.all([listObjects(prefix), listUploads(prefix)]);

  const what = recId ? `recording ${recId} of game ${gameId}` : `game ${gameId}`;
  const mb = objects.reduce((n, o) => n + o.bytes, 0) / 1e6;
  console.log(`${what} in account ${acct}`);
  console.log(`  table ${table}: ${keys.length} items`);
  for (const k of keys) console.log(`    ${k.pk}  ${k.sk}`);
  console.log(`  bucket ${bucket}: ${objects.length} objects (${mb.toFixed(1)} MB), ${uploads.length} unfinished uploads`);
  for (const o of objects) console.log(`    ${o.key}`);
  for (const u of uploads) console.log(`    ${u.key} (multipart ${u.uploadId.slice(0, 12)}…)`);

  if (keys.length === 0 && objects.length === 0 && uploads.length === 0) {
    console.log('Nothing to delete.');
    return;
  }
  if (!args.yes) {
    console.log('\nDry run. Pass --yes to delete.');
    return;
  }

  // S3 first: if this stops partway, the table still points at what's left
  // and running the script again finishes the job.
  for (const u of uploads) {
    await s3.send(new AbortMultipartUploadCommand({ Bucket: bucket, Key: u.key, UploadId: u.uploadId }));
  }
  await deleteObjects(objects.map((o) => o.key));
  await deleteItems(keys);
  console.log(`\nDeleted ${what}.`);

  if (recId) {
    const left = await query(pk, `REC#${gameId}#`);
    if (left.length === 0) console.log(`Game ${gameId} has no recordings left; delete it with --game ${gameId} alone.`);
  }
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
