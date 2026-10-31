// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Upload permission links (docs/API.md, "Upload permission link"): the game
 * page links to this site's /grant page with only the ticket, in the
 * fragment so it never reaches the web server's logs. That page needs no
 * sign-in; it looks the ticket up (POST /grants/lookup) and opens the app.
 */

const TICKET = /^osbg_[A-Za-z0-9_-]{43}$/;
const KEYS = ['v', 'api', 'account', 'game', 'ticket', 'exp'] as const;

export interface GrantLink {
	apiUrl: string;
	accountId: string;
	gameId: string;
	ticket: string;
	expiresAt: string;
	/** `opensportsball://grant?...`, what the page's button opens. */
	appUri: string;
}

/** What a /grant link holds: just the ticket, or (links made before
 *  2026-10-29) every parameter the app needs. */
export type GrantFragment = { ticket: string } | { link: GrantLink };

/** The /grant link for [ticket] on [origin]. */
export function grantPageUrl(origin: string, ticket: string): string {
	return `${origin.replace(/\/+$/, '')}/grant#${ticket}`;
}

/** The /grant page's fragment, or null if it is neither a ticket nor a
 *  whole, version-1 long link. */
export function parseGrantFragment(hash: string): GrantFragment | null {
	const raw = hash.replace(/^#/, '');
	if (TICKET.test(raw)) return { ticket: raw };
	const q = new URLSearchParams(raw);
	if (q.get('v') !== '1' || KEYS.some((k) => !q.get(k))) return null;
	const api = q.get('api')!;
	if (!/^https:\/\/[^/]+/.test(api) || !TICKET.test(q.get('ticket')!)) return null;
	if (Number.isNaN(Date.parse(q.get('exp')!))) return null;
	const clean = new URLSearchParams(KEYS.map((k) => [k, q.get(k)!]));
	return {
		link: {
			apiUrl: api,
			accountId: q.get('account')!,
			gameId: q.get('game')!,
			ticket: q.get('ticket')!,
			expiresAt: q.get('exp')!,
			appUri: `opensportsball://grant?${clean}`
		}
	};
}
