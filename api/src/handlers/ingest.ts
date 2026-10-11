// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** S3 ObjectCreated: notes each segment file that lands in the bucket.
 *  Usually `POST /uploads/complete` has already done this; the event covers
 *  a phone that finished the upload but never got the response. */

import type { S3Event } from 'aws-lambda';
import { recordObject } from '../lib/recordings.js';
import { parseSegmentKey } from '../lib/store.js';

export async function handler(event: S3Event): Promise<void> {
  for (const record of event.Records) {
    // S3 event keys are URL-encoded, with spaces as '+'.
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));
    const parsed = parseSegmentKey(key);
    if (!parsed) {
      console.log('ignoring object', key);
      continue;
    }
    await recordObject({ ...parsed, bytes: record.s3.object.size });
  }
}
