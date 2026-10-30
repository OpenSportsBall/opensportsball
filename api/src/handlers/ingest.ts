// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** S3 ObjectCreated: notes each segment file that lands in the bucket.
 *  Usually `POST /uploads/complete` has already done this; the event covers
 *  a phone that finished the upload but never got the response. A file that
 *  lands after its recording was deleted is deleted too. */

import { DeleteObjectCommand } from '@aws-sdk/client-s3';
import type { S3Event } from 'aws-lambda';
import { ApiError } from '../lib/http.js';
import { recordObject } from '../lib/recordings.js';
import { config, parseSegmentKey, s3 } from '../lib/store.js';

export async function handler(event: S3Event): Promise<void> {
  for (const record of event.Records) {
    // S3 event keys are URL-encoded, with spaces as '+'.
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));
    const parsed = parseSegmentKey(key);
    if (!parsed) {
      console.log('ignoring object', key);
      continue;
    }
    try {
      await recordObject({ ...parsed, bytes: record.s3.object.size });
    } catch (e) {
      if (!(e instanceof ApiError && e.status === 410)) throw e;
      console.log('deleting object of a deleted recording', key);
      await s3.send(new DeleteObjectCommand({ Bucket: config.bucket, Key: key }));
    }
  }
}
