// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Footage links: a person lets anyone holding a link download one
 *  recording's raw segments for a day, three days or a week, with no
 *  sign-in (the website's /footage page).
 *
 *  The link holds a token (`osbf_...`); only its hash is stored. The token
 *  itself downloads nothing: the page trades it (lookupFootageLink) for
 *  signed CloudFront URLs, which never outlast the link and are signed for
 *  at most 12 hours at a time. So stopping a link (revokeFootageLink) stops
 *  new pages at once, and a page already open within 12 hours.
 *
 *  Deleting the recording, its game or the account deletes its links
 *  (lib/deletion.ts). */

import { GetCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import { badRequest, conflict, gone, notFound } from './http.js';
import { deployedFootageSigner } from './footageUrls.js';
import { getRecording, listObjects, listReports, recordedAt, type RecordingItem, type ReportItem } from './recordings.js';
import { config, ddb, keys, manifestKey, queryPrefix, segmentKey } from './store.js';
import { FOOTAGE_LINK_HOURS, MAX_FOOTAGE_LINKS, hashToken, newFootageLinkToken } from './tokens.js';

/** The `TOKEN#` item of a footage link. No phone route accepts it: the
 *  authorizer only looks up device and grant tokens. */
interface FootageTokenItem {
  kind: 'footage';
  accountId: string;
  gameId: string;
  recordingId: string;
  expiresAtMs: number;
}

/** The account's record of a link, for listing and stopping it. Its id is
 *  the token's hash, which cannot be turned back into the link. */
interface FootageLinkItem {
  linkId: string;
  gameId: string;
  recordingId: string;
  createdAt: string;
  expiresAtMs: number;
}

const view = (l: FootageLinkItem) => ({
  linkId: l.linkId,
  createdAt: l.createdAt,
  expiresAt: new Date(l.expiresAtMs).toISOString(),
});

/** The recording's links that still work, oldest first. */
export async function listFootageLinks(acct: string, gameId: string, recordingId: string) {
  const now = Date.now();
  const items = await queryPrefix<FootageLinkItem>(acct, `FLINK#${gameId}#${recordingId}#`);
  return items
    .filter((l) => l.expiresAtMs > now) // DynamoDB's TTL deletes late
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt))
    .map(view);
}

export async function createFootageLink(acct: string, gameId: string, recordingId: string, hours: unknown) {
  if (!FOOTAGE_LINK_HOURS.includes(hours as number)) {
    throw badRequest(`"hours" must be one of ${FOOTAGE_LINK_HOURS.join(', ')}.`);
  }
  if (!(await getRecording(acct, gameId, recordingId))) throw notFound('No such recording.');
  if ((await listFootageLinks(acct, gameId, recordingId)).length >= MAX_FOOTAGE_LINKS) {
    throw conflict('This recording already has as many download pages as it can. Stop one first.');
  }
  const now = Date.now();
  const expiresAtMs = now + (hours as number) * 3600_000;
  const token = newFootageLinkToken();
  const linkId = hashToken(token);
  const ttl = Math.ceil(expiresAtMs / 1000) + 3600;
  const tokenItem: FootageTokenItem = { kind: 'footage', accountId: acct, gameId, recordingId, expiresAtMs };
  const link: FootageLinkItem = { linkId, gameId, recordingId, createdAt: new Date(now).toISOString(), expiresAtMs };
  await ddb.send(
    new TransactWriteCommand({
      TransactItems: [
        { Put: { TableName: config.table, Item: { ...keys.token(linkId), ...tokenItem, ttl } } },
        { Put: { TableName: config.table, Item: { ...keys.footageLink(acct, gameId, recordingId, linkId), ...link, ttl } } },
      ],
    }),
  );
  // The only time the token is known: the website shows the link once.
  return { ...view(link), gameId, recordingId, token };
}

export async function revokeFootageLink(acct: string, gameId: string, recordingId: string, linkId: string) {
  const key = keys.footageLink(acct, gameId, recordingId, linkId);
  if (!(await ddb.send(new GetCommand({ TableName: config.table, Key: key }))).Item) {
    throw notFound('No such download page.');
  }
  await ddb.send(
    new TransactWriteCommand({
      TransactItems: [
        { Delete: { TableName: config.table, Key: keys.token(linkId) } },
        { Delete: { TableName: config.table, Key: key } },
      ],
    }),
  );
}

/** Signed CloudFront links, good until [expiresAt], for every segment of a
 *  recording that has arrived, with the size and SHA-256 its phone listed,
 *  and for the merged manifest once the recording is ready. */
export async function signedFootage(acct: string, rec: RecordingItem, reports: ReportItem[], expiresAt: Date) {
  const { gameId, recordingId } = rec;
  const signer = await deployedFootageSigner();
  const objects = await listObjects(acct, gameId, recordingId);
  // What each phone listed, by "<deviceId>/<fileName>".
  const listed = new Map<string, { bytes: number; sha256: string }>();
  const devices = [...(rec.manifest?.devices ?? []), ...reports.map((r) => r.device)];
  for (const s of devices.flatMap((d) => d.segments ?? [])) listed.set(s.objectKey, s);
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
  return {
    // Written when the recording turns ready (recordings.ts: checkReady).
    manifestUrl: rec.status === 'ready' ? signer.url(manifestKey(acct, gameId, recordingId), expiresAt) : null,
    files,
  };
}

/** What the /footage page shows for [token]: the recording's segments,
 *  each with a signed link, and which phone each came from. */
export async function lookupFootageLink(token: string) {
  const r = await ddb.send(new GetCommand({ TableName: config.table, Key: keys.token(hashToken(token)) }));
  const item = r.Item as FootageTokenItem | undefined;
  if (!item || item.kind !== 'footage') throw notFound('That download page does not exist.');
  const now = Date.now();
  if (!(item.expiresAtMs > now)) throw gone('That download page has expired.');
  const { accountId: acct, gameId, recordingId } = item;
  const rec = await getRecording(acct, gameId, recordingId);
  if (!rec) throw notFound('That download page does not exist.');
  const reports = await listReports(acct, gameId, recordingId);
  // Whole seconds, as CloudFront counts: rounding up would outlast the link.
  const until = Math.min(item.expiresAtMs, now + config.downloadUrlTtlSeconds * 1000);
  const linksExpireAt = new Date(Math.floor(until / 1000) * 1000);
  const phones = new Map<string, { deviceId: string; role: string; model: string }>();
  for (const d of [...(rec.manifest?.devices ?? []), ...reports.map((p) => p.device)]) {
    phones.set(d.deviceId, { deviceId: d.deviceId, role: d.role, model: d.model });
  }
  return {
    recordedAt: recordedAt(rec, reports),
    status: rec.status,
    expiresAt: new Date(item.expiresAtMs).toISOString(),
    linksExpireAt: linksExpireAt.toISOString(),
    devices: [...phones.values()],
    ...(await signedFootage(acct, rec, reports, linksExpireAt)),
  };
}
