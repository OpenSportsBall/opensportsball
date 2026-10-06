// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/** Manifest validation: the shared JSON schema, then the rules a schema
 *  can't express (ids match the path, the caller is Main, devices belong to
 *  the account, files are named for their device). */

import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormatsModule from 'ajv-formats';
import schema from '../../../shared/schemas/manifest.schema.json' with { type: 'json' };
import { ApiError, badRequest, forbidden } from './http.js';
import { segmentFileName } from './store.js';

export interface ManifestSegment {
  index: number;
  objectKey: string;
  bytes: number;
  sha256: string;
  startedAtDeviceMs: number;
  durationMs: number;
}

export interface ManifestDevice {
  deviceId: string;
  role: 'main' | 'secondary';
  model: string;
  platform: 'ios' | 'android';
  segments: ManifestSegment[];
}

export interface Manifest {
  schemaVersion: 1;
  gameId: string;
  sessionId: string;
  createdAt: string;
  devices: ManifestDevice[];
}

// ajv-formats is CommonJS; its default export arrives wrapped under ESM.
const addFormats = ((addFormatsModule as unknown as { default?: unknown }).default ??
  addFormatsModule) as (ajv: Ajv2020) => Ajv2020;

const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validate = ajv.compile(schema);

export function parseManifest(
  input: unknown,
  ctx: { gameId: string; recordingId: string; callerDeviceId: string },
): Manifest {
  if (!validate(input)) {
    throw new ApiError(
      400,
      'invalid_manifest',
      'The manifest does not match the schema.',
      (validate.errors ?? []).map((e) => `${e.instancePath || '/'} ${e.message ?? ''}`.trim()),
    );
  }
  const m = input as unknown as Manifest;
  if (m.gameId !== ctx.gameId || m.sessionId !== ctx.recordingId) {
    throw badRequest('The manifest is for a different game or recording than the URL.');
  }

  const mains = m.devices.filter((d) => d.role === 'main');
  if (mains.length !== 1) throw new ApiError(400, 'invalid_manifest', 'A manifest needs exactly one main device.');
  if (m.devices.length === 2 && m.devices.every((d) => d.role === 'main')) {
    throw new ApiError(400, 'invalid_manifest', 'The second device must be the secondary.');
  }
  if (new Set(m.devices.map((d) => d.deviceId)).size !== m.devices.length) {
    throw new ApiError(400, 'invalid_manifest', 'Device ids must be different.');
  }
  if (mains[0]!.deviceId !== ctx.callerDeviceId) {
    throw forbidden('Only the main phone can upload the manifest.');
  }

  for (const d of m.devices) {
    const pattern = segmentFileName(d.deviceId);
    const indexes = new Set<number>();
    for (const s of d.segments) {
      const [dir, file, ...rest] = s.objectKey.split('/');
      if (dir !== d.deviceId || !file || rest.length > 0 || !pattern.test(file)) {
        throw new ApiError(400, 'invalid_manifest', `Segment ${s.objectKey} is not named for device ${d.deviceId}.`);
      }
      if (indexes.has(s.index)) {
        throw new ApiError(400, 'invalid_manifest', `Device ${d.deviceId} lists segment ${s.index} twice.`);
      }
      indexes.add(s.index);
    }
  }
  return m;
}

/** The part of a manifest the recording item keeps. */
export interface ExpectedDevice {
  deviceId: string;
  role: 'main' | 'secondary';
  model: string;
  files: { fileName: string; bytes: number }[];
}

export const expectedDevices = (m: Manifest): ExpectedDevice[] =>
  m.devices.map((d) => ({
    deviceId: d.deviceId,
    role: d.role,
    model: d.model,
    files: d.segments.map((s) => ({ fileName: s.objectKey.split('/')[1]!, bytes: s.bytes })),
  }));
