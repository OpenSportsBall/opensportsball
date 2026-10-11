// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import { defineConfig } from 'vitest/config';

export const MOTO_PORT = 5055;

// Tests run against moto (a local AWS emulator), started by
// test/globalSetup.ts. See test/README.md.
export default defineConfig({
  test: {
    globalSetup: ['test/globalSetup.ts'],
    fileParallelism: false,
    testTimeout: 20000,
    env: {
      AWS_ENDPOINT_URL: `http://127.0.0.1:${MOTO_PORT}`,
      AWS_REGION: 'us-east-1',
      AWS_ACCESS_KEY_ID: 'test',
      AWS_SECRET_ACCESS_KEY: 'test',
      S3_FORCE_PATH_STYLE: '1',
      TABLE_NAME: 'osb-test',
      BUCKET_NAME: 'osb-test-footage',
      PART_SIZE_BYTES: '100',
    },
  },
});
