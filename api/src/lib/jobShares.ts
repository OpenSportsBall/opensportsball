// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * What a cloud job's user agreed to share (the pitch map, the kit groups)
 * becomes a contribution, exactly as when the Mac app uploads one
 * (lib/contributions.ts): the same record, the same bucket, the same
 * consent version, listed and withdrawn on the Account page.
 *
 * The engine writes one contribution file per result
 * (shared/schemas/engine-contribution.schema.json) and its container puts
 * them in the job's output folder: `share/<name>.json`, and each file it
 * lists at `share/files/<path>`. Only results the user chose to share when
 * they answered that check are taken (job.shareConsent); anything else the
 * container wrote there is left to expire with the job's outputs.
 *
 * Best effort: a share that can't be filed is logged, and never fails the
 * job. The user's video matters more than our training data.
 */

import { CopyObjectCommand, GetObjectCommand, ListObjectsV2Command } from '@aws-sdk/client-s3';
import { completeContribution, createContribution, deleteContribution, fileKey } from './contributions.js';
import type { JobItem } from './jobs.js';
import { config, jobPrefix, s3 } from './store.js';

const SHARED_KINDS = ['pitch', 'kits'] as const;

export async function deliverShares(job: JobItem): Promise<string[]> {
  const consent = job.shareConsent ?? {};
  if (!config.contributionsBucketOrNull || !SHARED_KINDS.some((k) => consent[k])) return [];
  const dir = `${jobPrefix('outputs', job.accountId, job.gameId, job.recordingId, job.jobId)}share/`;
  const listed = await s3.send(new ListObjectsV2Command({ Bucket: config.bucket, Prefix: dir, Delimiter: '/' }));
  const filed: string[] = [];
  for (const o of listed.Contents ?? []) {
    if (!o.Key?.endsWith('.json')) continue;
    let id: string | undefined;
    try {
      const got = await s3.send(new GetObjectCommand({ Bucket: config.bucket, Key: o.Key }));
      const doc = JSON.parse(await got.Body!.transformToString()) as { kind?: string; files?: { path: string }[] };
      const version = consent[doc.kind as (typeof SHARED_KINDS)[number]];
      if (!version) continue; // not something this user agreed to share
      const created = await createContribution(job.accountId, {
        gameId: job.gameId,
        recordingId: job.recordingId,
        consentVersion: version,
        contribution: doc,
      });
      id = created.contributionId;
      for (const f of doc.files ?? []) {
        await s3.send(
          new CopyObjectCommand({
            Bucket: config.contributionsBucket,
            Key: fileKey(job.accountId, id, f.path),
            CopySource: encodeURI(`${config.bucket}/${dir}files/${f.path}`),
            // Stored with its SHA-256, which completing the contribution checks.
            ChecksumAlgorithm: 'SHA256',
          }),
        );
      }
      await completeContribution(job.accountId, id);
      filed.push(id);
    } catch (e) {
      console.error('could not file a shared result', o.Key, e);
      if (id) await deleteContribution(job.accountId, id).catch(() => {});
    }
  }
  return filed;
}
