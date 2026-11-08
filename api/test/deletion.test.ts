// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { randomBytes, randomUUID } from 'node:crypto';
import { ListMultipartUploadsCommand, ListObjectsV2Command, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { QueryCommand } from '@aws-sdk/lib-dynamodb';
import { beforeEach, describe, expect, it } from 'vitest';
import { handler as ingest } from '../src/handlers/ingest.js';
import { config, ddb, queryPrefix, segmentKey } from '../src/lib/store.js';
import {
  callDevice,
  callWeb,
  deviceEntry,
  fileName,
  linkPhone,
  manifest,
  resetAws,
  uploadFile,
  type Phone,
} from './helpers.js';

const s3 = new S3Client({ forcePathStyle: true });

const objectKeys = async (prefix: string) =>
  ((await s3.send(new ListObjectsV2Command({ Bucket: config.bucket, Prefix: prefix }))).Contents ?? []).map((o) => o.Key);
const openUploads = async (prefix: string) =>
  (await s3.send(new ListMultipartUploadsCommand({ Bucket: config.bucket, Prefix: prefix }))).Uploads ?? [];
/** The sort keys of an account's items, all of them or under [prefix]. */
async function sortKeys(acct: string, prefix?: string) {
  if (prefix) return (await queryPrefix<{ sk: string }>(acct, prefix)).map((i) => i.sk);
  const r = await ddb.send(
    new QueryCommand({
      TableName: config.table,
      KeyConditionExpression: 'pk = :pk',
      ExpressionAttributeValues: { ':pk': `ACCOUNT#${acct}` },
    }),
  );
  return (r.Items ?? []).map((i) => i.sk as string);
}

describe('deleting recordings and games', () => {
  let alice: string;
  let main: Phone;
  let secondary: Phone;
  let gameId: string;
  let recordingId: string;
  let otherRecordingId: string;
  const mainFiles = [randomBytes(250), randomBytes(120)];
  const secFiles = [randomBytes(30)];
  const recPath = (rec = recordingId) => ({ gameId, recordingId: rec });
  const gamePrefix = () => `accounts/${alice}/games/${gameId}/`;
  const recPrefix = (rec = recordingId) => `${gamePrefix()}recordings/${rec}/`;

  beforeEach(async () => {
    await resetAws();
    alice = randomUUID();
    main = await linkPhone(alice, 'Pixel 9');
    gameId = randomUUID();
    recordingId = randomUUID();
    otherRecordingId = randomUUID();
    secondary = { deviceId: randomUUID(), token: '', model: 'Galaxy S25' };
  });

  const putManifest = (m: unknown, rec = recordingId) =>
    callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', { path: recPath(rec), body: m });
  const putReport = (phone: Phone, body: unknown, rec = recordingId) =>
    callDevice(phone.token, 'PUT /games/{gameId}/recordings/{recordingId}/report', { path: recPath(rec), body });
  const deleteRecording = (acct: string, rec = recordingId) =>
    callWeb(acct, 'DELETE /games/{gameId}/recordings/{recordingId}', { path: recPath(rec) });
  const deleteGame = (acct: string) => callWeb(acct, 'DELETE /games/{gameId}', { path: { gameId } });

  /** A recording with: the Secondary on a grant, its report, one finished
   *  file of Main's, and one Main never finished (an open multipart upload). */
  async function record(rec = recordingId) {
    const g = await callDevice(main.token, 'POST /games/{gameId}/grants', {
      path: { gameId },
      body: { deviceId: secondary.deviceId },
    });
    secondary = { ...secondary, token: g.body.grantToken };
    expect((await putManifest(manifest(gameId, rec, main, mainFiles, secondary), rec)).status).toBe(200);
    expect((await uploadFile(main, gameId, rec, 0, mainFiles[0]!)).status).toBe(200);
    expect((await uploadFile(main, gameId, rec, 1, mainFiles[1]!, 1)).status).toBe(0);
    expect((await uploadFile(secondary, gameId, rec, 0, secFiles[0]!)).status).toBe(200);
    expect((await putReport(secondary, deviceEntry(secondary, 'secondary', secFiles), rec)).status).toBe(200);
  }

  it('the owner deletes one recording: its footage and items go, the rest of the game stays', async () => {
    await record();
    await record(otherRecordingId);
    expect(await objectKeys(recPrefix())).toHaveLength(2);
    expect(await openUploads(recPrefix())).toHaveLength(1);

    expect((await deleteRecording(alice)).status).toBe(204);

    expect(await objectKeys(recPrefix())).toEqual([]);
    expect(await openUploads(recPrefix())).toEqual([]);
    const left = await sortKeys(alice);
    expect(left.filter((sk) => sk.includes(recordingId) && !sk.startsWith('DELETED#'))).toEqual([]);
    expect(left).toContain(`DELETED#${gameId}#${recordingId}`);

    expect(await objectKeys(recPrefix(otherRecordingId))).toHaveLength(2);
    const game = await callWeb(alice, 'GET /games/{gameId}', { path: { gameId } });
    expect(game.body.recordings.map((r: any) => r.recordingId)).toEqual([otherRecordingId]);

    // Again (say, after a timeout) is fine; one that never existed is not.
    expect((await deleteRecording(alice)).status).toBe(204);
    expect((await deleteRecording(alice, randomUUID())).status).toBe(404);
  });

  it('a game with every recording deleted has no status, not "waiting for manifest"', async () => {
    // Like the game that prompted this: one recording, never got a manifest.
    expect((await uploadFile(main, gameId, recordingId, 0, mainFiles[0]!)).status).toBe(200);
    expect((await callWeb(alice, 'GET /games')).body.games[0].status).toBe('waiting_for_manifest');
    expect((await deleteRecording(alice)).status).toBe(204);
    const games = (await callWeb(alice, 'GET /games')).body.games;
    expect(games.find((g: any) => g.gameId === gameId)).toMatchObject({ recordingCount: 0, status: null });
    expect((await deleteGame(alice)).status).toBe(204);
  });

  it('other accounts cannot delete a recording or game', async () => {
    await record();
    const mallory = randomUUID();
    expect((await deleteRecording(mallory)).status).toBe(404);
    expect((await deleteGame(mallory)).status).toBe(404);
    expect(await objectKeys(recPrefix())).toHaveLength(2);
    expect((await callWeb(alice, 'GET /games/{gameId}', { path: { gameId } })).body.recordings).toHaveLength(1);
    // A failed attempt leaves no marker on either account.
    expect(await sortKeys(mallory)).toEqual([]);
    expect(await sortKeys(alice, 'DELETED#')).toEqual([]);
  });

  it('phones still uploading a deleted recording are refused, not let in to recreate it', async () => {
    await record();
    expect((await deleteRecording(alice)).status).toBe(204);

    const again = await uploadFile(main, gameId, recordingId, 0, mainFiles[0]!);
    expect(again.status).toBe(410);
    expect(again.body.message).toBe('This recording was deleted on the website.');
    expect((await uploadFile(secondary, gameId, recordingId, 0, secFiles[0]!)).status).toBe(410);
    expect((await putManifest(manifest(gameId, recordingId, main, mainFiles))).status).toBe(410);
    expect((await putReport(secondary, deviceEntry(secondary, 'secondary', secFiles))).status).toBe(410);
    const complete = await callDevice(main.token, 'POST /uploads/complete', {
      body: { gameId, recordingId, fileName: fileName(main, 1), uploadId: 'x', parts: [] },
    });
    expect(complete.status).toBe(410);

    // A file that lands anyway (an upload finished as it was deleted) is removed.
    const key = segmentKey(alice, gameId, recordingId, main.deviceId, fileName(main, 0));
    await s3.send(new PutObjectCommand({ Bucket: config.bucket, Key: key, Body: mainFiles[0]! }));
    await ingest(s3Event(key, mainFiles[0]!.length));
    expect(await objectKeys(recPrefix())).toEqual([]);

    expect(await sortKeys(alice, `REC#${gameId}#${recordingId}`)).toEqual([]);
    expect((await callWeb(alice, 'GET /games/{gameId}', { path: { gameId } })).body.recordings).toEqual([]);
    // Other recordings of the game still upload.
    expect((await uploadFile(main, gameId, otherRecordingId, 0, mainFiles[0]!)).status).toBe(200);
  });

  it('the owner deletes a whole game: footage, recordings, grants and its website tickets', async () => {
    await record();
    await record(otherRecordingId);
    const ticket = await callWeb(alice, 'POST /games/{gameId}/grant-tickets', { path: { gameId } });
    expect(ticket.status).toBe(201);
    const otherGame = randomUUID();
    expect((await uploadFile(main, otherGame, randomUUID(), 0, mainFiles[0]!)).status).toBe(200);

    expect((await deleteGame(alice)).status).toBe(204);

    expect(await objectKeys(gamePrefix())).toEqual([]);
    expect(await openUploads(gamePrefix())).toEqual([]);
    const left = await sortKeys(alice);
    expect(left.filter((sk) => sk.includes(gameId))).toEqual([`DELETED#${gameId}`]);
    expect((await callWeb(alice, 'GET /games/{gameId}', { path: { gameId } })).status).toBe(404);
    expect((await callWeb(alice, 'GET /games')).body.games.map((g: any) => g.gameId)).toEqual([otherGame]);

    // The website ticket is gone; the Secondary's grant hears the game was deleted.
    const redeem = await callDevice(null, 'POST /grants/redeem', {
      body: { ticket: ticket.body.ticket, gameId, deviceId: randomUUID() },
    });
    expect(redeem.status).toBe(404);
    const late = await uploadFile(secondary, gameId, recordingId, 0, secFiles[0]!);
    expect(late.status).toBe(410);
    expect(late.body.message).toBe('This game was deleted on the website.');
    expect((await uploadFile(main, gameId, randomUUID(), 0, mainFiles[0]!)).status).toBe(410);
    expect(await sortKeys(alice, `GAME#${gameId}`)).toEqual([]);

    expect((await deleteGame(alice)).status).toBe(204);
    expect((await callWeb(alice, 'DELETE /games/{gameId}', { path: { gameId: randomUUID() } })).status).toBe(404);
  });

  it('rejects ids that are not UUIDs', async () => {
    const r = await callWeb(alice, 'DELETE /games/{gameId}', { path: { gameId: '..' } });
    expect(r.status).toBe(400);
  });
});

function s3Event(key: string, size: number) {
  return {
    Records: [{ s3: { bucket: { name: config.bucket }, object: { key: encodeURIComponent(key).replace(/%2F/g, '/'), size } } }],
  } as any;
}
