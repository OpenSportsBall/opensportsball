// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Routes for people signed in on the website (Cognito JWT authorizer). */

import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import { GetCommand, PutCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import type { APIGatewayProxyEventV2WithJWTAuthorizer } from 'aws-lambda';
import { json, notFound, pathParam, respond, type Result } from '../lib/http.js';
import {
  STATUS_ORDER,
  listObjects,
  type ObjectItem,
  type RecordingItem,
  type RecordingStatus,
} from '../lib/recordings.js';
import { config, ddb, keys, queryPrefix } from '../lib/store.js';
import { LINK_CODE_TTL_MS, newLinkCode } from '../lib/tokens.js';

interface DeviceItem {
  deviceId: string;
  platform: string;
  model: string;
  linkedAt: string;
  lastSeenAt?: string;
  tokenHash: string;
}

interface GameItem {
  gameId: string;
  createdAt: string;
}

export const handler = (event: APIGatewayProxyEventV2WithJWTAuthorizer): Promise<Result> =>
  respond(async () => {
    const claims = event.requestContext.authorizer.jwt.claims;
    const acct = String(claims.sub);
    switch (event.routeKey) {
      case 'GET /me':
        return json(200, { accountId: acct, email: claims.email ?? null });
      case 'POST /link-codes':
        return createLinkCode(acct, event);
      case 'GET /devices':
        return listDevices(acct);
      case 'DELETE /devices/{deviceId}':
        return unlinkDevice(acct, pathParam(event, 'deviceId'));
      case 'GET /games':
        return listGames(acct);
      case 'GET /games/{gameId}':
        return getGame(acct, pathParam(event, 'gameId'));
      default:
        throw notFound(`No route ${event.routeKey}.`);
    }
  });

async function createLinkCode(acct: string, event: APIGatewayProxyEventV2WithJWTAuthorizer) {
  const expiresAtMs = Date.now() + LINK_CODE_TTL_MS;
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = newLinkCode();
    try {
      await ddb.send(
        new PutCommand({
          TableName: config.table,
          Item: {
            ...keys.linkCode(code),
            accountId: acct,
            expiresAtMs,
            ttl: Math.ceil(expiresAtMs / 1000) + 3600,
          },
          ConditionExpression: 'attribute_not_exists(pk)',
        }),
      );
      // The phone needs the API URL too; this request came in on it.
      const apiUrl = `https://${event.requestContext.domainName}`;
      return json(201, {
        code,
        expiresAt: new Date(expiresAtMs).toISOString(),
        linkUri: `opensportsball://link?v=1&api=${encodeURIComponent(apiUrl)}&code=${code}`,
      });
    } catch (e) {
      if (!(e instanceof ConditionalCheckFailedException)) throw e;
    }
  }
  throw new Error('could not allocate a unique link code');
}

async function listDevices(acct: string) {
  const items = await queryPrefix<DeviceItem>(acct, 'DEVICE#');
  return json(200, {
    devices: items.map((d) => ({
      deviceId: d.deviceId,
      platform: d.platform,
      model: d.model,
      linkedAt: d.linkedAt,
      lastSeenAt: d.lastSeenAt ?? null,
    })),
  });
}

async function unlinkDevice(acct: string, deviceId: string) {
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.device(acct, deviceId) }));
  const device = r.Item as DeviceItem | undefined;
  if (!device) throw notFound('No such device on this account.');
  await ddb.send(
    new TransactWriteCommand({
      TransactItems: [
        { Delete: { TableName: config.table, Key: keys.device(acct, deviceId) } },
        { Delete: { TableName: config.table, Key: keys.owner(deviceId) } },
        { Delete: { TableName: config.table, Key: keys.token(device.tokenHash) } },
      ],
    }),
  );
  return json(204);
}

const leastFinished = (statuses: RecordingStatus[]) =>
  statuses.reduce<RecordingStatus>(
    (worst, s) => (STATUS_ORDER.indexOf(s) < STATUS_ORDER.indexOf(worst) ? s : worst),
    'ready',
  );

async function listGames(acct: string) {
  const [games, recordings] = await Promise.all([
    queryPrefix<GameItem>(acct, 'GAME#'),
    queryPrefix<RecordingItem>(acct, 'REC#'),
  ]);
  const byGame = new Map<string, RecordingItem[]>();
  for (const r of recordings) byGame.set(r.gameId, [...(byGame.get(r.gameId) ?? []), r]);
  const out = games.map((g) => {
    const recs = byGame.get(g.gameId) ?? [];
    return {
      gameId: g.gameId,
      createdAt: g.createdAt,
      recordingCount: recs.length,
      status: recs.length ? leastFinished(recs.map((r) => r.status)) : 'waiting_for_manifest',
    };
  });
  out.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return json(200, { games: out });
}

async function getGame(acct: string, gameId: string) {
  const g = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.game(acct, gameId) }));
  const game = g.Item as GameItem | undefined;
  if (!game) throw notFound('No such game.');
  const [recordings, objects] = await Promise.all([
    queryPrefix<RecordingItem>(acct, `REC#${gameId}#`),
    listObjects(acct, gameId),
  ]);
  recordings.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  return json(200, {
    gameId,
    createdAt: game.createdAt,
    recordings: recordings.map((r) => ({
      recordingId: r.recordingId,
      createdAt: r.createdAt,
      status: r.status,
      hasManifest: Boolean(r.expected),
      devices: recordingDevices(r, objects.filter((o) => o.recordingId === r.recordingId)),
    })),
  });
}

function recordingDevices(r: RecordingItem, objects: ObjectItem[]) {
  if (r.expected) {
    return r.expected.map((d) => {
      const wanted = new Map(d.files.map((f) => [f.fileName, f.bytes]));
      const arrived = objects.filter((o) => o.deviceId === d.deviceId && wanted.get(o.fileName) === o.bytes);
      return {
        deviceId: d.deviceId,
        role: d.role,
        model: d.model,
        expectedSegments: d.files.length,
        uploadedSegments: arrived.length,
        expectedBytes: d.files.reduce((sum, f) => sum + f.bytes, 0),
        uploadedBytes: arrived.reduce((sum, o) => sum + o.bytes, 0),
      };
    });
  }
  const byDevice = new Map<string, ObjectItem[]>();
  for (const o of objects) byDevice.set(o.deviceId, [...(byDevice.get(o.deviceId) ?? []), o]);
  return [...byDevice.entries()].map(([deviceId, objs]) => ({
    deviceId,
    role: null,
    model: null,
    expectedSegments: null,
    uploadedSegments: objs.length,
    expectedBytes: null,
    uploadedBytes: objs.reduce((sum, o) => sum + o.bytes, 0),
  }));
}
