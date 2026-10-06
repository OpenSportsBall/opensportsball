// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import { createHash, randomBytes, randomInt } from 'node:crypto';

/** `sbvd_` + 32 random bytes as base64url (43 characters). */
export const newDeviceToken = () => `sbvd_${randomBytes(32).toString('base64url')}`;

export const DEVICE_TOKEN = /^sbvd_[A-Za-z0-9_-]{43}$/;

/** Only hashes are stored, so a leaked table can't be used to upload. */
export const hashToken = (token: string) => createHash('sha256').update(token).digest('hex');

/** No 0/O, 1/I/L: easy to read aloud and type. */
export const LINK_CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
export const LINK_CODE = new RegExp(`^[${LINK_CODE_ALPHABET}]{8}$`);
export const LINK_CODE_TTL_MS = 10 * 60 * 1000;

export function newLinkCode(): string {
  let code = '';
  for (let i = 0; i < 8; i++) code += LINK_CODE_ALPHABET[randomInt(LINK_CODE_ALPHABET.length)];
  return code;
}
