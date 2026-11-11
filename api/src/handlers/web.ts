// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Routes for people signed in on the website (Cognito JWT authorizer). */

import { GetCommand } from '@aws-sdk/lib-dynamodb';
import type { APIGatewayProxyEventV2WithJWTAuthorizer } from 'aws-lambda';
import { isAdmin } from '../lib/admin.js';
import { badRequest, body, json, notFound, pathParam, respond, type Result } from '../lib/http.js';
import {
  answerCheck,
  cancelJob,
  getJob,
  getJobView,
  jobView,
  latestJobs,
  questionsView,
  reportLocal,
  startJob,
  videoLink,
} from '../lib/jobs.js';
import { getSettings } from '../lib/settings.js';
import { expectedDevices } from '../lib/manifest.js';
import { deployedFootageSigner } from '../lib/footageUrls.js';
import {
  STATUS_ORDER,
  getRecording,
  listObjects,
  listReports,
  recordedAt,
  reportMap,
  type ReportItem,
  type ObjectItem,
  type RecordingItem,
  type RecordingStatus,
} from '../lib/recordings.js';
import { config, ddb, keys, manifestKey, queryPrefix, segmentKey } from '../lib/store.js';
import { createLinkCode } from '../lib/linkCodes.js';
import { unlinkDevice, type DeviceItem } from '../lib/devices.js';
import { createGameTicket } from '../lib/grants.js';
import { deleteAccount, deleteGame, deleteRecording } from '../lib/deletion.js';
import {
  completeContribution,
  createContribution,
  deleteContribution,
  listContributions,
} from '../lib/contributions.js';

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
        return json(200, {
          accountId: acct,
          email: claims.email ?? null,
          admin: isAdmin(claims),
          cloudProcessing: (await getSettings(acct)).cloudProcessing,
        });
      case 'DELETE /me':
        await deleteAccount(acct);
        return json(204);
      case 'POST /link-codes':
        return json(201, await createLinkCode(acct, claims.email ? String(claims.email) : null, event.requestContext.domainName));
      case 'GET /devices':
        return listDevices(acct);
      case 'DELETE /devices/{deviceId}':
        await unlinkDevice(acct, pathParam(event, 'deviceId'));
        return json(204);
      case 'GET /games':
        return listGames(acct);
      case 'GET /games/{gameId}':
        return getGame(acct, pathParam(event, 'gameId'));
      case 'DELETE /games/{gameId}':
        await deleteGame(acct, pathParam(event, 'gameId'));
        return json(204);
      case 'DELETE /games/{gameId}/recordings/{recordingId}':
        await deleteRecording(acct, pathParam(event, 'gameId'), pathParam(event, 'recordingId'));
        return json(204);
      case 'POST /games/{gameId}/grant-tickets':
        return postGameTicket(acct, pathParam(event, 'gameId'), event.requestContext.domainName);
      case 'POST /games/{gameId}/recordings/{recordingId}/downloads':
        return postDownloads(acct, pathParam(event, 'gameId'), pathParam(event, 'recordingId'));
      case 'GET /contributions':
        return json(200, await listContributions(acct));
      case 'POST /contributions':
        return json(201, await createContribution(acct, body(event)));
      case 'POST /contributions/{contributionId}/complete':
        return json(200, await completeContribution(acct, pathParam(event, 'contributionId')));
      case 'DELETE /contributions/{contributionId}':
        await deleteContribution(acct, pathParam(event, 'contributionId'));
        return json(204);
      case 'POST /games/{gameId}/recordings/{recordingId}/jobs': {
        const where = body(event).where;
        if (where !== 'cloud' && where !== 'local') throw badRequest('"where" must be "cloud" or "local".');
        return json(201, await startJob(acct, pathParam(event, 'gameId'), pathParam(event, 'recordingId'), where));
      }
      case 'GET /games/{gameId}/recordings/{recordingId}/jobs/{jobId}':
        return json(200, await getJobView(acct, ...jobPath(event)));
      case 'DELETE /games/{gameId}/recordings/{recordingId}/jobs/{jobId}':
        await cancelJob(await getJob(acct, ...jobPath(event)));
        return json(204);
      case 'GET /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/questions':
        return json(200, await questionsView(await getJob(acct, ...jobPath(event))));
      case 'PUT /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/answers':
        return json(200, await answerCheck(await getJob(acct, ...jobPath(event)), body(event)));
      case 'PUT /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/status':
        return json(200, await reportLocal(await getJob(acct, ...jobPath(event)), body(event)));
      case 'POST /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/downloads':
        return json(200, await videoLink(await getJob(acct, ...jobPath(event))));
      default:
        throw notFound(`No route ${event.routeKey}.`);
    }
  });

const jobPath = (event: APIGatewayProxyEventV2WithJWTAuthorizer): [string, string, string] => [
  pathParam(event, 'gameId'),
  pathParam(event, 'recordingId'),
  pathParam(event, 'jobId'),
];

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

/** The earliest of the known times (ISO timestamps compare as strings). */
const earliest = (times: (string | null)[]) =>
  times.reduce<string | null>((min, t) => (t !== null && (min === null || t < min) ? t : min), null);

/** Upload-time fallback for anything whose recording time is not known yet. */
const when = (x: { createdAt: string; recordedAt: string | null }) => x.recordedAt ?? x.createdAt;

const leastFinished = (statuses: RecordingStatus[]) =>
  statuses.reduce<RecordingStatus>(
    (worst, s) => (STATUS_ORDER.indexOf(s) < STATUS_ORDER.indexOf(worst) ? s : worst),
    'ready',
  );

async function listGames(acct: string) {
  const [games, recordings, reports] = await Promise.all([
    queryPrefix<GameItem>(acct, 'GAME#'),
    queryPrefix<RecordingItem>(acct, 'REC#'),
    queryPrefix<ReportItem>(acct, 'REPORT#'),
  ]);
  const byGame = new Map<string, RecordingItem[]>();
  for (const r of recordings) byGame.set(r.gameId, [...(byGame.get(r.gameId) ?? []), r]);
  const out = games.map((g) => {
    const recs = byGame.get(g.gameId) ?? [];
    return {
      gameId: g.gameId,
      createdAt: g.createdAt,
      recordedAt: earliest(
        recs.map((r) => recordedAt(r, reports.filter((p) => p.gameId === g.gameId && p.recordingId === r.recordingId))),
      ),
      recordingCount: recs.length,
      // Null once every recording is deleted: nothing is waiting for anything.
      status: recs.length ? leastFinished(recs.map((r) => r.status)) : null,
    };
  });
  out.sort((a, b) => when(b).localeCompare(when(a)));
  return json(200, { games: out });
}

/** A link for a phone that recorded this game without a grant from Main. */
async function postGameTicket(acct: string, gameId: string, apiDomain: string) {
  const g = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.game(acct, gameId) }));
  if (!g.Item) throw notFound('No such game.');
  return json(201, await createGameTicket({ accountId: acct, gameId, apiDomain }));
}

/** Signed CloudFront links for every segment of a recording that has
 *  arrived, with the size and SHA-256 its phone listed, and for the merged
 *  manifest once the recording is ready. */
async function postDownloads(acct: string, gameId: string, recordingId: string) {
  const rec = await getRecording(acct, gameId, recordingId);
  if (!rec) throw notFound('No such recording.');
  const signer = await deployedFootageSigner();
  const [objects, reports] = await Promise.all([
    listObjects(acct, gameId, recordingId),
    listReports(acct, gameId, recordingId),
  ]);
  // What each phone listed, by "<deviceId>/<fileName>".
  const listed = new Map<string, { bytes: number; sha256: string }>();
  const devices = [...(rec.manifest?.devices ?? []), ...reports.map((r) => r.device)];
  for (const s of devices.flatMap((d) => d.segments ?? [])) listed.set(s.objectKey, s);
  const expiresAt = new Date(Date.now() + config.downloadUrlTtlSeconds * 1000);
  const files = objects
    .map((o) => {
      const l = listed.get(`${o.deviceId}/${o.fileName}`);
      return {
        deviceId: o.deviceId,
        fileName: o.fileName,
        bytes: o.bytes,
        sha256: l && l.bytes === o.bytes ? l.sha256 : null,
        url: signer.url(segmentKey(acct, gameId, recordingId, o.deviceId, o.fileName), expiresAt),
      };
    })
    .sort((a, b) => a.deviceId.localeCompare(b.deviceId) || a.fileName.localeCompare(b.fileName));
  return json(200, {
    gameId,
    recordingId,
    status: rec.status,
    expiresAt: expiresAt.toISOString(),
    // Written when the recording turns ready (recordings.ts: checkReady).
    manifestUrl: rec.status === 'ready' ? signer.url(manifestKey(acct, gameId, recordingId), expiresAt) : null,
    files,
  });
}

async function getGame(acct: string, gameId: string) {
  const g = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.game(acct, gameId) }));
  const game = g.Item as GameItem | undefined;
  if (!game) throw notFound('No such game.');
  const [recordings, objects, reports, jobs] = await Promise.all([
    queryPrefix<RecordingItem>(acct, `REC#${gameId}#`),
    listObjects(acct, gameId),
    listReports(acct, gameId),
    latestJobs(acct, gameId),
  ]);
  const recs = recordings.map((r) => ({
    item: r,
    createdAt: r.createdAt,
    recordedAt: recordedAt(r, reports.filter((p) => p.recordingId === r.recordingId)),
  }));
  recs.sort((a, b) => when(a).localeCompare(when(b)));
  return json(200, {
    gameId,
    createdAt: game.createdAt,
    recordedAt: earliest(recs.map((r) => r.recordedAt)),
    recordings: recs.map(({ item: r, recordedAt }) => ({
      recordingId: r.recordingId,
      createdAt: r.createdAt,
      recordedAt,
      status: r.status,
      hasManifest: Boolean(r.manifest),
      devices: recordingDevices(
        r,
        objects.filter((o) => o.recordingId === r.recordingId),
        reports.filter((p) => p.recordingId === r.recordingId),
      ),
      // The newest processing job, or null when it was never processed.
      job: jobs.has(r.recordingId) ? jobView(jobs.get(r.recordingId)!, r) : null,
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
