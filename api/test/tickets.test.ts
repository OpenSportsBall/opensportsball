// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { randomBytes, randomUUID } from 'node:crypto';
import { UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { beforeEach, describe, expect, it } from 'vitest';
import { ANONYMOUS, handler as authorizer } from '../src/handlers/authorizer.js';
import { config, ddb, keys } from '../src/lib/store.js';
import { hashToken } from '../src/lib/tokens.js';
import {
  callDevice,
  deviceEntry,
  linkPhone,
  manifest,
  readyEvents,
  resetAws,
  uploadFile,
  type Phone,
} from './helpers.js';

const authorize = (token: string) => authorizer({ headers: { authorization: `Bearer ${token}` } } as any);

/** Main without signal at the field: it hands Secondary a ticket fetched
 *  earlier, and either phone binds it once it reaches the internet. */
describe('grant tickets', () => {
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

  const tickets = (count: number, by = main.token) => callDevice(by, 'POST /grant-tickets', { body: { count } });
  const redeem = (ticket: string, game = gameId, deviceId: string = secondaryId) =>
    callDevice(null, 'POST /grants/redeem', { body: { ticket, gameId: game, deviceId } });
  const path = () => ({ gameId, recordingId });
  const putManifest = (secondary: Phone) =>
    callDevice(main.token, 'PUT /games/{gameId}/recordings/{recordingId}/manifest', {
      path: path(),
      body: manifest(gameId, recordingId, main, mainFiles, secondary),
    });

  async function oneTicket() {
    const r = await tickets(1);
    expect(r.status).toBe(201);
    return r.body.tickets[0].ticket as string;
  }

  /** Both phones upload everything; returns the Secondary's report result. */
  async function upload(secondary: Phone) {
    for (const [i, f] of mainFiles.entries()) await uploadFile(main, gameId, recordingId, i, f);
    for (const [i, f] of secFiles.entries()) {
      expect((await uploadFile(secondary, gameId, recordingId, i, f)).status).toBe(200);
    }
    return callDevice(secondary.token, 'PUT /games/{gameId}/recordings/{recordingId}/report', {
      path: path(),
      body: deviceEntry(secondary, 'secondary', secFiles),
    });
  }

  it('Main keeps a capped stock of tickets', async () => {
    const r = await tickets(3);
    expect(r.status).toBe(201);
    expect(r.body).toMatchObject({ accountId: alice, open: 3, apiUrl: expect.stringMatching(/^https:\/\//) });
    expect(r.body.tickets).toHaveLength(3);
    for (const t of r.body.tickets) {
      expect(t.ticket).toMatch(/^osbg_[A-Za-z0-9_-]{43}$/);
      expect(Date.parse(t.expiresAt) - Date.now()).toBeGreaterThan(89 * 24 * 3600 * 1000);
    }
    // At most 5 open per phone.
    expect((await tickets(5)).body).toMatchObject({ open: 5, tickets: expect.any(Array) });
    expect((await tickets(5)).body.tickets).toHaveLength(0);
    // Another Main phone on the account has its own stock.
    const other = await linkPhone(alice, 'Pixel 10');
    expect((await tickets(2, other.token)).body.tickets).toHaveLength(2);
  });

  it('an unredeemed ticket can call nothing', async () => {
    const ticket = await oneTicket();
    expect(await authorize(ticket)).toEqual(ANONYMOUS);
    const r = await uploadFile({ deviceId: secondaryId, token: ticket, model: 'x' }, gameId, recordingId, 0, secFiles[0]!);
    expect(r.status).toBe(401);
  });

  it('Secondary redeems first, then the recording completes in Main\'s account', async () => {
    const ticket = await oneTicket();
    const r = await redeem(ticket);
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ grantToken: ticket, accountId: alice, gameId, deviceId: secondaryId });
    expect(await authorize(ticket)).toEqual({
      isAuthorized: true,
      context: { accountId: alice, deviceId: secondaryId, grantGameId: gameId },
    });

    const secondary: Phone = { deviceId: secondaryId, token: ticket, model: 'Galaxy S25' };
    expect((await putManifest(secondary)).status).toBe(200);
    expect((await upload(secondary)).body).toEqual({ status: 'ready', missing: [], awaitingReports: [] });
    expect(await readyEvents()).toHaveLength(1);

    // Main redeeming the same binding later is a no-op with the same answer.
    const again = await redeem(ticket);
    expect(again.status).toBe(200);
    expect(again.body.expiresAt).toBe(r.body.expiresAt);
  });

  it('Main redeems first; Secondary then uploads with the ticket as is', async () => {
    const ticket = await oneTicket();
    expect((await redeem(ticket)).status).toBe(200);
    const secondary: Phone = { deviceId: secondaryId, token: ticket, model: 'Galaxy S25' };
    expect((await putManifest(secondary)).status).toBe(200);
    expect((await upload(secondary)).body.status).toBe('ready');
  });

  it('Main\'s manifest waits for the ticket to be redeemed', async () => {
    const ticket = await oneTicket();
    const secondary: Phone = { deviceId: secondaryId, token: ticket, model: 'Galaxy S25' };
    expect((await putManifest(secondary)).status).toBe(403);
    await redeem(ticket);
    expect((await putManifest(secondary)).status).toBe(200);
  });

  it('a redeemed ticket frees a place in the stock', async () => {
    const r = await tickets(5);
    expect((await tickets(1)).body.tickets).toHaveLength(0);
    await redeem(r.body.tickets[0].ticket);
    expect((await tickets(1)).body.tickets).toHaveLength(1);
  });

  it('refuses a second binding, unknown and expired tickets, and Main itself', async () => {
    const ticket = await oneTicket();
    expect((await redeem(ticket)).status).toBe(200);
    expect((await redeem(ticket, randomUUID())).status).toBe(409);
    expect((await redeem(ticket, gameId, randomUUID())).status).toBe(409);

    expect((await redeem(`osbg_${'A'.repeat(43)}`)).status).toBe(404);
    expect((await redeem('not-a-ticket')).status).toBe(400);

    const old = await oneTicket();
    await ddb.send(
      new UpdateCommand({
        TableName: config.table,
        Key: keys.token(hashToken(old)),
        UpdateExpression: 'SET ticketExpiresAtMs = :past',
        ExpressionAttributeValues: { ':past': Date.now() - 1000 },
      }),
    );
    expect((await redeem(old)).status).toBe(410);

    expect((await redeem(await oneTicket(), gameId, main.deviceId)).status).toBe(400);
  });

  it('only a device token can fetch tickets', async () => {
    const ticket = await oneTicket();
    await redeem(ticket);
    expect((await tickets(1, ticket)).status).toBe(403);
    expect((await tickets(1, `osbd_${'A'.repeat(43)}`)).status).toBe(401);
  });
});
