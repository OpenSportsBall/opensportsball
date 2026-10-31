// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { randomBytes, randomUUID } from 'node:crypto';
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { beforeEach, describe, expect, it } from 'vitest';
import { ANONYMOUS, handler as authorizer } from '../src/handlers/authorizer.js';
import { config, manifestKey } from '../src/lib/store.js';
import {
  callDevice,
  callWeb,
  deviceEntry,
  linkPhone,
  manifest,
  readyEvents,
  resetAws,
  uploadFile,
  type Phone,
} from './helpers.js';

const s3 = new S3Client({ forcePathStyle: true });
const authorize = (token: string) => authorizer({ headers: { authorization: `Bearer ${token}` } } as any);

/** Main recorded without being linked, so its Secondary never got a grant
 *  and Main's manifest leaves it out. Later the website gives that phone a
 *  ticket for the game, in a link. */
describe('a Secondary that never got a grant', () => {
  let alice: string;
  let main: Phone;
  let gameId: string;
  let recordingId: string;
  const secondaryId = randomUUID();
  const mainFiles = [randomBytes(250)];
  const secFiles = [randomBytes(1), randomBytes(120)];

  beforeEach(async () => {
    await resetAws();
    alice = randomUUID();
    main = await linkPhone(alice, 'Pixel 9');
    gameId = randomUUID();
    recordingId = randomUUID();
  });

  const path = () => ({ gameId, recordingId });
  const gameTicket = (game = gameId, acct = alice) =>
    callWeb(acct, 'POST /games/{gameId}/grant-tickets', { path: { gameId: game } });
  const redeem = (ticket: string, game = gameId, deviceId = secondaryId) =>
    callDevice(null, 'POST /grants/redeem', { body: { ticket, gameId: game, deviceId } });

  /** Main records alone as far as the server knows, and finishes. */
  async function mainAlone() {
    const r = await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
      path: path(),
      body: manifest(gameId, recordingId, main, mainFiles),
    });
    expect(r.status).toBe(200);
    for (const [i, f] of mainFiles.entries()) await uploadFile(main, gameId, recordingId, i, f);
  }

  async function secondaryUploads(secondary: Phone) {
    const r = await callDevice(secondary.token, 'PUT /games/{gameId}/recordings/{recordingId}/report', {
      path: path(),
      body: deviceEntry(secondary, 'secondary', secFiles),
    });
    expect(r.status).toBe(200);
    for (const [i, f] of secFiles.entries()) {
      expect((await uploadFile(secondary, gameId, recordingId, i, f)).status).toBe(200);
    }
    return r;
  }

  const status = async () =>
    (await callWeb(alice, 'GET /games/{gameId}', { path: { gameId } })).body.recordings[0].status;

  async function ticketFor(): Promise<string> {
    const r = await gameTicket();
    expect(r.status).toBe(201);
    return r.body.ticket;
  }

  it('the website makes a ticket for one of its games, as a link the phone opens', async () => {
    await mainAlone();
    const r = await gameTicket();
    expect(r.status).toBe(201);
    expect(r.body).toEqual({
      ticket: expect.stringMatching(/^osbg_[A-Za-z0-9_-]{43}$/),
      apiUrl: 'https://abc123.execute-api.us-east-1.amazonaws.com',
      accountId: alice,
      gameId,
      expiresAt: expect.any(String),
      appUri: expect.stringMatching(/^opensportsball:\/\/grant\?/),
    });
    const days = (Date.parse(r.body.expiresAt) - Date.now()) / 86_400_000;
    expect(days).toBeGreaterThan(6.9);
    expect(days).toBeLessThanOrEqual(7);
    const q = new URL(r.body.appUri).searchParams;
    expect(Object.fromEntries(q)).toEqual({
      v: '1',
      api: r.body.apiUrl,
      account: alice,
      game: gameId,
      ticket: r.body.ticket,
      exp: r.body.expiresAt,
    });
    // Unredeemed, it can call nothing.
    expect(await authorize(r.body.ticket)).toEqual(ANONYMOUS);
  });

  it('the /grant page looks a website ticket up, so the link can hold only the ticket', async () => {
    await mainAlone();
    const made = (await gameTicket()).body;
    const lookup = (ticket: string) => callDevice(null, 'POST /grants/lookup', { body: { ticket } });

    const r = await lookup(made.ticket);
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ...made, used: false });

    // Once a phone has it, the same answer says so (that phone may open it again).
    await redeem(made.ticket);
    const after = await lookup(made.ticket);
    expect(after.status).toBe(200);
    expect(after.body).toMatchObject({ ticket: made.ticket, gameId, accountId: alice, used: true });
    expect(after.body.appUri).toMatch(/^opensportsball:\/\/grant\?/);

    // Main's own tickets, unknown ones and malformed ones are not looked up.
    const mains = await callDevice(main.token, 'POST /grant-tickets', { body: { count: 1 } });
    expect((await lookup(mains.body.tickets[0].ticket)).status).toBe(404);
    expect((await lookup('osbg_' + 'x'.repeat(43))).status).toBe(404);
    expect((await lookup('nope')).status).toBe(400);
  });

  it('only for games on the account', async () => {
    expect((await gameTicket(randomUUID())).status).toBe(404);
    await mainAlone();
    expect((await gameTicket(gameId, randomUUID())).status).toBe(404);
  });

  it('it can only be bound to its own game', async () => {
    await mainAlone();
    const ticket = await ticketFor();
    expect((await redeem(ticket, randomUUID())).status).toBe(409);
    // A refused game does not use it up.
    expect((await redeem(ticket)).status).toBe(200);
    // Bound to one phone: another phone opening the same link is refused.
    expect((await redeem(ticket, gameId, randomUUID())).status).toBe(409);
  });

  it('a recording that was ready opens again for the late Secondary, then is ready with both', async () => {
    await mainAlone();
    expect(await status()).toBe('ready');
    expect(await readyEvents()).toHaveLength(1);

    const ticket = await ticketFor();
    const r = await redeem(ticket);
    expect(r.status).toBe(200);
    const secondary: Phone = { deviceId: secondaryId, token: r.body.grantToken, model: 'iPhone 17' };

    const report = await secondaryUploads(secondary);
    expect(report.body).toMatchObject({ status: 'uploading', awaitingReports: [] });
    expect(report.body.missing).toHaveLength(secFiles.length);
    expect(await status()).toBe('ready');
    expect(await readyEvents()).toHaveLength(1); // a second one: the first was read above

    const stored = await s3.send(new GetObjectCommand({ Bucket: config.bucket, Key: manifestKey(alice, gameId, recordingId) }));
    const merged = JSON.parse(await stored.Body!.transformToString());
    expect(merged.devices.map((d: any) => [d.deviceId, d.role])).toEqual([
      [main.deviceId, 'main'],
      [secondaryId, 'secondary'],
    ]);
    expect(merged.devices[1].segments).toEqual(deviceEntry(secondary, 'secondary', secFiles).segments);

    const game = (await callWeb(alice, 'GET /games/{gameId}', { path: { gameId } })).body;
    expect(game.recordings[0].devices).toMatchObject([
      { deviceId: main.deviceId, role: 'main', uploadedSegments: 1, expectedSegments: 1 },
      { deviceId: secondaryId, role: 'secondary', uploadedSegments: 2, expectedSegments: 2 },
    ]);

    // Its report again is fine; a different one now is not.
    const again = await callDevice(secondary.token, 'PUT /games/{gameId}/recordings/{recordingId}/report', {
      path: path(),
      body: deviceEntry(secondary, 'secondary', secFiles),
    });
    expect(again.body.status).toBe('ready');
    const changed = await callDevice(secondary.token, 'PUT /games/{gameId}/recordings/{recordingId}/report', {
      path: path(),
      body: deviceEntry(secondary, 'secondary', [secFiles[0]!]),
    });
    expect(changed.status).toBe(409);
  });

  it('before Main is done, the late Secondary is simply waited for', async () => {
    await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
      path: path(),
      body: manifest(gameId, recordingId, main, mainFiles),
    });
    const r = await redeem(await ticketFor());
    const secondary: Phone = { deviceId: secondaryId, token: r.body.grantToken, model: 'iPhone 17' };
    await secondaryUploads(secondary);
    expect(await status()).toBe('uploading');
    await uploadFile(main, gameId, recordingId, 0, mainFiles[0]!);
    expect(await status()).toBe('ready');
    expect(await readyEvents()).toHaveLength(1);
  });

  it('a second Secondary is not added to a recording that already has one', async () => {
    const other: Phone = { deviceId: randomUUID(), token: '', model: 'Galaxy' };
    const g = await callDevice(main.token, 'POST /games/{gameId}/grants', {
      path: { gameId },
      body: { deviceId: other.deviceId },
    });
    other.token = g.body.grantToken;
    await callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
      path: path(),
      body: manifest(gameId, recordingId, main, mainFiles, other, secFiles),
    });
    await uploadFile(main, gameId, recordingId, 0, mainFiles[0]!);
    for (const [i, f] of secFiles.entries()) await uploadFile(other, gameId, recordingId, i, f);
    expect(await readyEvents()).toHaveLength(1);

    const r = await redeem(await ticketFor());
    const late = await callDevice(r.body.grantToken, 'PUT /games/{gameId}/recordings/{recordingId}/report', {
      path: path(),
      body: deviceEntry({ deviceId: secondaryId, token: '', model: 'iPhone 17' }, 'secondary', secFiles),
    });
    expect(late.status).toBe(409);
  });
});
