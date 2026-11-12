// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Footage links (docs/API.md, "Footage links"): the game page makes a link
 * to this site's /footage page that holds only a token, in the fragment so
 * it never reaches the web server's logs. That page needs no sign-in; it
 * trades the token (POST /footage-links/lookup) for the recording's files.
 */

import type { FootageFile, FootagePage } from './types';

const TOKEN = /^osbf_[A-Za-z0-9_-]{43}$/;

/** How long a download page may work, as the API takes it. */
export const FOOTAGE_LINK_HOURS = [
	{ hours: 24, label: '1 day' },
	{ hours: 72, label: '3 days' },
	{ hours: 168, label: '7 days' }
] as const;

/** The /footage link for [token] on [origin]. */
export function footagePageUrl(origin: string, token: string): string {
	return `${origin.replace(/\/+$/, '')}/footage#${token}`;
}

/** The token in the /footage page's fragment, or null if it is not one. */
export function parseFootageFragment(hash: string): string | null {
	const raw = hash.replace(/^#/, '');
	return TOKEN.test(raw) ? raw : null;
}

export interface FootagePhone {
	deviceId: string;
	role: string | null;
	model: string | null;
	files: FootageFile[];
	bytes: number;
}

/** The page's files by phone, the main camera first, each phone's in
 *  recording order. A phone no manifest has named yet has no role or model. */
export function footageByPhone(page: Pick<FootagePage, 'devices' | 'files'>): FootagePhone[] {
	const phones = new Map<string, FootagePhone>();
	const phone = (deviceId: string) => {
		if (!phones.has(deviceId)) phones.set(deviceId, { deviceId, role: null, model: null, files: [], bytes: 0 });
		return phones.get(deviceId)!;
	};
	for (const d of page.devices) Object.assign(phone(d.deviceId), { role: d.role, model: d.model });
	for (const f of page.files) {
		const p = phone(f.deviceId);
		p.files.push(f);
		p.bytes += f.bytes;
	}
	const order = (p: FootagePhone) => (p.role === 'main' ? 0 : p.role === 'secondary' ? 1 : 2);
	return [...phones.values()]
		.filter((p) => p.files.length > 0)
		.map((p) => ({ ...p, files: [...p.files].sort((a, b) => a.fileName.localeCompare(b.fileName)) }))
		.sort((a, b) => order(a) - order(b) || a.deviceId.localeCompare(b.deviceId));
}
