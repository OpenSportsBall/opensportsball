// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Manifest and device report validation: the shared JSON schema, then the
 *  rules a schema can't express (ids match the path, the caller is Main or
 *  the reporting phone, files are named for their device), and merging the
 *  two into the full manifest processing reads.
 *
 *  Main's manifest lists both phones but only Main's segments; each other
 *  phone reports its own segments when it reaches the internet, so the
 *  phones never need to be near each other to finish an upload. */

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
  /** Omitted for a phone that reports its own segments. */
  segments?: ManifestSegment[];
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
const validateDevice = ajv.getSchema(`${schema.$id}#/$defs/device`)!;

function schemaError(errors: typeof validate.errors, what: string): ApiError {
  return new ApiError(
    400,
    'invalid_manifest',
    `The ${what} does not match the schema.`,
    (errors ?? []).map((e) => `${e.instancePath || '/'} ${e.message ?? ''}`.trim()),
  );
}

/** Segment files must be named for their device, each index once. */
function checkSegments(d: ManifestDevice) {
  const pattern = segmentFileName(d.deviceId);
  const indexes = new Set<number>();
  for (const s of d.segments ?? []) {
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

export function parseManifest(
  input: unknown,
  ctx: { gameId: string; recordingId: string; callerDeviceId: string },
): Manifest {
  if (!validate(input)) throw schemaError(validate.errors, 'manifest');
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

  if (!mains[0]!.segments?.length) {
    throw new ApiError(400, 'invalid_manifest', 'The main device must list its segments.');
  }
  m.devices.forEach(checkSegments);
  return m;
}

/** A phone's report of its own part of a recording: the schema's device
 *  entry, with its segments. */
export function parseReport(input: unknown, ctx: { callerDeviceId: string }): ManifestDevice {
  if (!validateDevice(input)) throw schemaError(validateDevice.errors, 'report');
  const d = input as unknown as ManifestDevice;
  if (d.deviceId !== ctx.callerDeviceId) throw forbidden('A phone can only report its own segments.');
  if (!d.segments?.length) throw new ApiError(400, 'invalid_manifest', 'A report must list its segments.');
  checkSegments(d);
  return d;
}

/** What one phone is expected to upload; `files` is null until that phone
 *  reports its segments. */
export interface ExpectedDevice {
  deviceId: string;
  role: 'main' | 'secondary';
  model: string;
  files: { fileName: string; bytes: number }[] | null;
}

/** Segments for each device: the phone's own report wins over what Main's
 *  manifest says. */
function segmentsFor(d: ManifestDevice, reports: Map<string, ManifestDevice>) {
  return reports.get(d.deviceId)?.segments ?? d.segments ?? null;
}

/** Main's devices, plus a Secondary Main's manifest leaves out because it
 *  never got a grant at the field, once that phone reports with one given
 *  later (a game ticket from the website, lib/grants.ts). Only phones linked
 *  to the account or holding a grant can report at all. */
export function withLateSecondary(m: Manifest, reports: Map<string, ManifestDevice>): ManifestDevice[] {
  if (m.devices.some((d) => d.role === 'secondary')) return m.devices;
  const late = [...reports.values()].find((d) => d.role === 'secondary');
  return late ? [...m.devices, late] : m.devices;
}

export const expectedDevices = (m: Manifest, reports: Map<string, ManifestDevice>): ExpectedDevice[] =>
  withLateSecondary(m, reports).map((d) => ({
    deviceId: d.deviceId,
    role: d.role,
    model: d.model,
    files: segmentsFor(d, reports)?.map((s) => ({ fileName: s.objectKey.split('/')[1]!, bytes: s.bytes })) ?? null,
  }));

/** The full manifest for processing: Main's, with every device's segments
 *  filled in. Only valid once every device has segments. */
export const mergeManifest = (m: Manifest, reports: Map<string, ManifestDevice>): Manifest => ({
  ...m,
  devices: withLateSecondary(m, reports).map((d) => ({ ...d, segments: segmentsFor(d, reports) ?? [] })),
});
