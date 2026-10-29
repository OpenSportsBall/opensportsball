// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Upload permission links (docs/API.md, "Upload permission link"): the game
 * page turns a ticket's `appUri` into an https link to this site's /grant
 * page, which needs no sign-in and opens the app. The parameters ride in
 * the fragment, so the ticket never reaches the web server's logs.
 */

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

/** The https link for [appUri] (`opensportsball://grant?...`) on [origin]. */
export function grantPageUrl(origin: string, appUri: string): string {
	const query = appUri.slice(appUri.indexOf('?') + 1);
	return `${origin.replace(/\/+$/, '')}/grant#${query}`;
}

/** The link's parameters from the /grant page's fragment, or null if it is
 *  not a whole, version-1 link. */
export function parseGrantFragment(hash: string): GrantLink | null {
	const q = new URLSearchParams(hash.replace(/^#/, ''));
	if (q.get('v') !== '1' || KEYS.some((k) => !q.get(k))) return null;
	const api = q.get('api')!;
	if (!/^https:\/\/[^/]+/.test(api) || !/^osbg_[A-Za-z0-9_-]{43}$/.test(q.get('ticket')!)) return null;
	if (Number.isNaN(Date.parse(q.get('exp')!))) return null;
	const clean = new URLSearchParams(KEYS.map((k) => [k, q.get(k)!]));
	return {
		apiUrl: api,
		accountId: q.get('account')!,
		gameId: q.get('game')!,
		ticket: q.get('ticket')!,
		expiresAt: q.get('exp')!,
		appUri: `opensportsball://grant?${clean}`
	};
}
