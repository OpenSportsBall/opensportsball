// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Who may use the admin routes: members of the Cognito group below. */

/** Add a user with `aws cognito-idp admin-add-user-to-group` (api/README.md). */
export const ADMIN_GROUP = 'admins';

/** The Cognito groups in an access token's claims. API Gateway's JWT
 *  authorizer passes an array claim on as one string, `"[admins other]"`;
 *  a real array is accepted too. */
export function groupsOf(claims: Record<string, unknown>): string[] {
  const raw = claims['cognito:groups'];
  if (Array.isArray(raw)) return raw.map(String);
  if (typeof raw !== 'string') return [];
  return raw
    .replace(/^\[|\]$/g, '')
    .split(/[\s,]+/)
    .filter(Boolean);
}

export const isAdmin = (claims: Record<string, unknown>) => groupsOf(claims).includes(ADMIN_GROUP);
