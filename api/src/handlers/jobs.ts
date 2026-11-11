// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** EventBridge "Batch Job State Change": moves a processing job on when
 *  its Batch job starts or ends, and emails the account when the checks
 *  are waiting, the video is ready, or processing failed (lib/jobs.ts). */

import type { EventBridgeEvent } from 'aws-lambda';
import { sendJobEmail } from '../lib/email.js';
import { deliverShares } from '../lib/jobShares.js';
import { onBatchStateChange, type BatchStateChange } from '../lib/jobs.js';

export async function handler(event: EventBridgeEvent<'Batch Job State Change', BatchStateChange>): Promise<void> {
  const d = event.detail;
  const result = await onBatchStateChange(d);
  console.log(JSON.stringify({ batchJob: d.jobName, status: d.status, reason: d.statusReason ?? null, told: result?.kind ?? null }));
  if (result?.kind === 'done') {
    // What the user agreed to share, now that the engine has written it.
    try {
      const filed = await deliverShares(result.job);
      if (filed.length) console.log(JSON.stringify({ shared: filed, job: result.job.jobId }));
    } catch (e) {
      console.error('could not file the shared results', e);
    }
  }
  if (result) await sendJobEmail(result);
}
