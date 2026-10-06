// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/** Response helpers, errors and input validation shared by the handlers. */

import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from 'aws-lambda';

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

export const badRequest = (message: string) => new ApiError(400, 'bad_request', message);
export const forbidden = (message: string) => new ApiError(403, 'forbidden', message);
export const notFound = (message: string) => new ApiError(404, 'not_found', message);
export const conflict = (message: string) => new ApiError(409, 'conflict', message);
export const gone = (message: string) => new ApiError(410, 'gone', message);

export type Result = APIGatewayProxyStructuredResultV2;

export function json(statusCode: number, body?: unknown): Result {
  if (body === undefined) return { statusCode };
  return {
    statusCode,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  };
}

/** Runs a route handler, turning ApiErrors into their responses and
 *  anything else into a logged 500. */
export async function respond(fn: () => Promise<Result>): Promise<Result> {
  try {
    return await fn();
  } catch (e) {
    if (e instanceof ApiError) {
      return json(e.status, {
        error: e.code,
        message: e.message,
        ...(e.details === undefined ? {} : { details: e.details }),
      });
    }
    console.error('unhandled error', e);
    return json(500, { error: 'internal', message: 'Something went wrong.' });
  }
}

export function body(event: APIGatewayProxyEventV2): Record<string, unknown> {
  if (!event.body) throw badRequest('Request body is required.');
  const text = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body;
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw badRequest('Request body is not valid JSON.');
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw badRequest('Request body must be a JSON object.');
  }
  return parsed as Record<string, unknown>;
}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const SHA256_HEX = /^[0-9a-f]{64}$/;

export function str(o: Record<string, unknown>, field: string, pattern?: RegExp, maxLength = 200): string {
  const v = o[field];
  if (typeof v !== 'string' || v.length === 0 || v.length > maxLength) {
    throw badRequest(`"${field}" must be a non-empty string.`);
  }
  if (pattern && !pattern.test(v)) throw badRequest(`"${field}" is not in the expected format.`);
  return v;
}

export function int(o: Record<string, unknown>, field: string, min: number, max: number): number {
  const v = o[field];
  if (typeof v !== 'number' || !Number.isInteger(v) || v < min || v > max) {
    throw badRequest(`"${field}" must be an integer from ${min} to ${max}.`);
  }
  return v;
}

export function pathParam(event: APIGatewayProxyEventV2, name: string, pattern = UUID): string {
  const v = event.pathParameters?.[name];
  if (!v || !pattern.test(v)) throw badRequest(`Path parameter "${name}" is not valid.`);
  return v;
}
