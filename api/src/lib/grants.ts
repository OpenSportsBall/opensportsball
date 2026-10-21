// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Recording grants: Main, with its device token, lets another phone
 *  upload that phone's own report and segments for one game into Main's
 *  account. The other phone stays linked to its own account, if any.
 *
 *  A grant token can only call the report and upload routes, only for its
 *  game, and only as its device (handlers/device.ts). It expires after
 *  GRANT_TTL_MS. Asking again for the same game and phone replaces it. */

import { TransactionCanceledException } from '@aws-sdk/client-dynamodb';
import { GetCommand, PutCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import { badRequest, conflict, gone, notFound } from './http.js';
import { config, ddb, keys, queryPrefix } from './store.js';
import { GRANT_TTL_MS, MAX_OPEN_TICKETS, TICKET_TTL_MS, hashToken, newGrantToken } from './tokens.js';

/** The `TOKEN#` item of a grant token. A ticket (below) has no gameId,
 *  deviceId or expiresAtMs until it is redeemed, so the authorizer treats
 *  it as no identity. */
export interface GrantTokenItem {
  kind: 'grant';
  accountId: string;
  deviceId: string;
  gameId: string;
  expiresAtMs: number;
  /** Set on tickets: Main's deviceId, and when an unbound ticket lapses. */
  issuedBy?: string;
  ticketExpiresAtMs?: number;
}

/** The account's record of a grant, for checking manifests and listing. */
export interface GrantItem {
  gameId: string;
  deviceId: string;
  tokenHash: string;
  issuedBy: string;
  createdAt: string;
  expiresAt: string;
}

export async function getGrant(acct: string, gameId: string, deviceId: string) {
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.grant(acct, gameId, deviceId) }));
  return r.Item as GrantItem | undefined;
}

/** [issuedBy] is Main's deviceId; [apiDomain] the domain the request came
 *  in on, which the other phone needs too. */
export async function createGrant(o: {
  accountId: string;
  gameId: string;
  deviceId: string;
  issuedBy: string;
  apiDomain: string;
}) {
  const now = Date.now();
  const expiresAtMs = now + GRANT_TTL_MS;
  const token = newGrantToken();
  const tokenHash = hashToken(token);
  const previous = await getGrant(o.accountId, o.gameId, o.deviceId);
  const tokenItem: GrantTokenItem = {
    kind: 'grant',
    accountId: o.accountId,
    deviceId: o.deviceId,
    gameId: o.gameId,
    expiresAtMs,
  };
  const grant: GrantItem = {
    gameId: o.gameId,
    deviceId: o.deviceId,
    tokenHash,
    issuedBy: o.issuedBy,
    createdAt: new Date(now).toISOString(),
    expiresAt: new Date(expiresAtMs).toISOString(),
  };
  await ddb.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: config.table,
            Item: { ...keys.token(tokenHash), ...tokenItem, ttl: Math.ceil(expiresAtMs / 1000) + 3600 },
          },
        },
        // Kept after the token expires: the manifest check and, later,
        // the Secondary owner's "Contributed to" list use it.
        { Put: { TableName: config.table, Item: { ...keys.grant(o.accountId, o.gameId, o.deviceId), ...grant } } },
        ...(previous ? [{ Delete: { TableName: config.table, Key: keys.token(previous.tokenHash) } }] : []),
      ],
    }),
  );
  return {
    grantToken: token,
    apiUrl: `https://${o.apiDomain}`,
    accountId: o.accountId,
    gameId: o.gameId,
    deviceId: o.deviceId,
    expiresAt: grant.expiresAt,
  };
}

// --- Grant tickets ----------------------------------------------------------
//
// A Main phone without signal at the field can't ask for a grant while the
// phones are paired. So while it has internet it keeps a few tickets: grant
// tokens bound to its account but to no game or phone yet. At the field it
// hands one to Secondary over Bluetooth; whichever phone reaches the
// internet first redeems it for (game, phone), and from then on the ticket
// is an ordinary grant token. Unredeemed tickets can't call anything.

/** The account's record of an unbound ticket, to cap how many are open. */
interface TicketItem {
  issuedBy: string;
  tokenHash: string;
  expiresAtMs: number;
}

/** Tops Main's stock of unbound tickets up to [count] (at most
 *  MAX_OPEN_TICKETS open at once) and returns the new ones. */
export async function createTickets(o: { accountId: string; issuedBy: string; count: number; apiDomain: string }) {
  const now = Date.now();
  const open = (await queryPrefix<TicketItem>(o.accountId, 'TICKET#')).filter(
    (t) => t.issuedBy === o.issuedBy && t.expiresAtMs > now,
  ).length;
  const n = Math.max(0, Math.min(o.count, MAX_OPEN_TICKETS - open));
  const expiresAtMs = now + TICKET_TTL_MS;
  const tickets: { ticket: string; expiresAt: string }[] = [];
  for (let i = 0; i < n; i++) {
    const token = newGrantToken();
    const tokenHash = hashToken(token);
    const ttl = Math.ceil(expiresAtMs / 1000) + 3600;
    await ddb.send(
      new TransactWriteCommand({
        TransactItems: [
          {
            Put: {
              TableName: config.table,
              Item: {
                ...keys.token(tokenHash),
                kind: 'grant',
                accountId: o.accountId,
                issuedBy: o.issuedBy,
                ticketExpiresAtMs: expiresAtMs,
                ttl,
              },
            },
          },
          {
            Put: {
              TableName: config.table,
              Item: { ...keys.ticket(o.accountId, tokenHash), issuedBy: o.issuedBy, tokenHash, expiresAtMs, ttl },
            },
          },
        ],
      }),
    );
    tickets.push({ ticket: token, expiresAt: new Date(expiresAtMs).toISOString() });
  }
  return { tickets, apiUrl: `https://${o.apiDomain}`, accountId: o.accountId, open: open + n };
}

/** Binds a ticket to [gameId] and [deviceId], making it that phone's grant
 *  for that game. Either phone may call it, in any order: the same binding
 *  again returns the same grant; a different one is refused. */
export async function redeemTicket(o: { ticket: string; gameId: string; deviceId: string; apiDomain: string }) {
  const tokenHash = hashToken(o.ticket);
  for (let attempt = 0; attempt < 2; attempt++) {
    const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.token(tokenHash) }));
    const item = r.Item as (GrantTokenItem & { kind?: string }) | undefined;
    if (!item || item.kind !== 'grant') throw notFound('That upload permission does not exist.');
    const answer = (expiresAtMs: number) => ({
      grantToken: o.ticket,
      apiUrl: `https://${o.apiDomain}`,
      accountId: item.accountId,
      gameId: o.gameId,
      deviceId: o.deviceId,
      expiresAt: new Date(expiresAtMs).toISOString(),
    });

    if (item.gameId) {
      if (item.gameId === o.gameId && item.deviceId === o.deviceId) return answer(item.expiresAtMs);
      throw conflict('That upload permission is already in use for another game or phone.');
    }
    if (!(Number(item.ticketExpiresAtMs) > Date.now())) throw gone('That upload permission has expired.');
    if (item.issuedBy === o.deviceId) throw badRequest('A phone does not need a grant for itself.');

    const now = Date.now();
    const expiresAtMs = now + GRANT_TTL_MS;
    const previous = await getGrant(item.accountId, o.gameId, o.deviceId);
    const grant: GrantItem = {
      gameId: o.gameId,
      deviceId: o.deviceId,
      tokenHash,
      issuedBy: item.issuedBy ?? '',
      createdAt: new Date(now).toISOString(),
      expiresAt: new Date(expiresAtMs).toISOString(),
    };
    try {
      await ddb.send(
        new TransactWriteCommand({
          TransactItems: [
            {
              Update: {
                TableName: config.table,
                Key: keys.token(tokenHash),
                UpdateExpression: 'SET gameId = :g, deviceId = :d, expiresAtMs = :e, #ttl = :ttl REMOVE ticketExpiresAtMs',
                ConditionExpression: 'attribute_not_exists(gameId)',
                ExpressionAttributeNames: { '#ttl': 'ttl' }, // a reserved word
                ExpressionAttributeValues: {
                  ':g': o.gameId,
                  ':d': o.deviceId,
                  ':e': expiresAtMs,
                  ':ttl': Math.ceil(expiresAtMs / 1000) + 3600,
                },
              },
            },
            {
              Put: {
                TableName: config.table,
                Item: { ...keys.grant(item.accountId, o.gameId, o.deviceId), ...grant, viaTicket: true },
              },
            },
            { Delete: { TableName: config.table, Key: keys.ticket(item.accountId, tokenHash) } },
            ...(previous && previous.tokenHash !== tokenHash
              ? [{ Delete: { TableName: config.table, Key: keys.token(previous.tokenHash) } }]
              : []),
          ],
        }),
      );
      return answer(expiresAtMs);
    } catch (e) {
      // The other phone redeemed it at the same moment: read it again.
      if (e instanceof TransactionCanceledException && e.CancellationReasons?.[0]?.Code === 'ConditionalCheckFailed') {
        continue;
      }
      throw e;
    }
  }
  throw conflict('That upload permission changed while it was being used. Try again.');
}
