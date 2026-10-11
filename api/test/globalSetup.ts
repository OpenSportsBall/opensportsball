// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Starts moto_server (local AWS emulator) for the test run. Set
 *  MOTO_SERVER to its path, or put it on PATH (`pip install "moto[server]"`). */

import { spawn, type ChildProcess } from 'node:child_process';
import { MOTO_PORT } from '../vitest.config.js';

let proc: ChildProcess | undefined;

export async function setup() {
  const bin = process.env.MOTO_SERVER ?? 'moto_server';
  proc = spawn(bin, ['-H', '127.0.0.1', '-p', String(MOTO_PORT)], {
    // S3 normally rejects parts under 5 MiB; the tests use 100-byte parts.
    env: { ...process.env, S3_UPLOAD_PART_MIN_SIZE: '1' },
    stdio: 'ignore',
  });
  proc.on('error', (e) => {
    throw new Error(`could not start ${bin}: ${e.message}. Install with: pip install "moto[server]"`);
  });
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(`http://127.0.0.1:${MOTO_PORT}/moto-api/`);
      if (r.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error('moto_server did not start');
}

export async function teardown() {
  proc?.kill();
}
