// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Routes for people signed in on the website (Cognito JWT authorizer). */

import { GetCommand } from '@aws-sdk/lib-dynamodb';
import type { APIGatewayProxyEventV2WithJWTAuthorizer } from 'aws-lambda';
import { json, notFound, pathParam, respond, type Result } from '../lib/http.js';
import { expectedDevices } from '../lib/manifest.js';
import {
  STATUS_ORDER,
  listObjects,
  listReports,
  reportMap,
  type ReportItem,
  type ObjectItem,
  type RecordingItem,
  type RecordingStatus,
} from '../lib/recordings.js';
import { config, ddb, keys, queryPrefix } from '../lib/store.js';
import { createLinkCode } from '../lib/linkCodes.js';
import { unlinkDevice, type DeviceItem } from '../lib/devices.js';

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
        return json(201, await createLinkCode(acct, event.requestContext.domainName));
      case 'GET /devices':
        return listDevices(acct);
      case 'DELETE /devices/{deviceId}':
        await unlinkDevice(acct, pathParam(event, 'deviceId'));
        return json(204);
      case 'GET /games':
        return listGames(acct);
      case 'GET /games/{gameId}':
        return getGame(acct, pathParam(event, 'gameId'));
      default:
        throw notFound(`No route ${event.routeKey}.`);
    }
  });

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
  const [recordings, objects, reports] = await Promise.all([
    queryPrefix<RecordingItem>(acct, `REC#${gameId}#`),
    listObjects(acct, gameId),
    listReports(acct, gameId),
  ]);
  recordings.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  return json(200, {
    gameId,
    createdAt: game.createdAt,
    recordings: recordings.map((r) => ({
      recordingId: r.recordingId,
      createdAt: r.createdAt,
      status: r.status,
      hasManifest: Boolean(r.manifest),
      devices: recordingDevices(
        r,
        objects.filter((o) => o.recordingId === r.recordingId),
        reports.filter((p) => p.recordingId === r.recordingId),
      ),
    })),
  });
}

function recordingDevices(r: RecordingItem, objects: ObjectItem[], reports: ReportItem[]) {
  if (r.manifest) {
    return expectedDevices(r.manifest, reportMap(reports)).map((d) => {
      const mine = objects.filter((o) => o.deviceId === d.deviceId);
      if (d.files === null) {
        // That phone has not reported its segments yet.
        return {
          deviceId: d.deviceId,
          role: d.role,
          model: d.model,
          expectedSegments: null,
          uploadedSegments: mine.length,
          expectedBytes: null,
          uploadedBytes: mine.reduce((sum, o) => sum + o.bytes, 0),
        };
      }
      const wanted = new Map(d.files.map((f) => [f.fileName, f.bytes]));
      const arrived = mine.filter((o) => wanted.get(o.fileName) === o.bytes);
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
