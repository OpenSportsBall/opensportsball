// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** EventBridge "Batch Job State Change": moves a processing job on when
 *  its Batch job starts or ends, and emails the account when the checks
 *  are waiting, the video is ready, or processing failed (lib/jobs.ts). */

import type { EventBridgeEvent } from 'aws-lambda';
import { sendJobEmail } from '../lib/email.js';
import { onBatchStateChange, type BatchStateChange } from '../lib/jobs.js';

export async function handler(event: EventBridgeEvent<'Batch Job State Change', BatchStateChange>): Promise<void> {
  const d = event.detail;
  const result = await onBatchStateChange(d);
  console.log(JSON.stringify({ batchJob: d.jobName, status: d.status, reason: d.statusReason ?? null, told: result?.kind ?? null }));
  if (result) await sendJobEmail(result);
}
