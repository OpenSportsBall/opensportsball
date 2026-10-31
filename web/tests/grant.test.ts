// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it } from 'vitest';
import { grantPageUrl, parseGrantFragment } from '../src/lib/grant.ts';

const ticket = 'osbg_' + 'a'.repeat(43);
const params = new URLSearchParams({
	v: '1',
	api: 'https://abc.execute-api.us-east-1.amazonaws.com',
	account: 'acct-1',
	game: 'game-1',
	ticket,
	exp: '2026-11-04T05:00:00.000Z'
});
const appUri = `opensportsball://grant?${params}`;

describe('grant links', () => {
	it('hold only the ticket, in the fragment', () => {
		const url = grantPageUrl('https://site.example/', ticket);
		expect(url).toBe(`https://site.example/grant#${ticket}`);
		expect(new URL(url).search).toBe('');
		expect(parseGrantFragment(new URL(url).hash)).toEqual({ ticket });
	});

	it('still read links that carried every parameter', () => {
		expect(parseGrantFragment(`#${params}`)).toEqual({
			link: {
				apiUrl: 'https://abc.execute-api.us-east-1.amazonaws.com',
				accountId: 'acct-1',
				gameId: 'game-1',
				ticket,
				expiresAt: '2026-11-04T05:00:00.000Z',
				appUri
			}
		});
	});

	it('refuse partial or odd links', () => {
		const without = (k: string) => {
			const p = new URLSearchParams(params);
			p.delete(k);
			return `#${p}`;
		};
		expect(parseGrantFragment('')).toBeNull();
		expect(parseGrantFragment('#osbg_short')).toBeNull();
		expect(parseGrantFragment('#osbd_' + 'a'.repeat(43))).toBeNull();
		for (const k of ['v', 'api', 'account', 'game', 'ticket', 'exp']) expect(parseGrantFragment(without(k))).toBeNull();
		const set = (k: string, v: string) => {
			const p = new URLSearchParams(params);
			p.set(k, v);
			return `#${p}`;
		};
		expect(parseGrantFragment(set('v', '2'))).toBeNull();
		expect(parseGrantFragment(set('api', 'http://abc.example'))).toBeNull();
		expect(parseGrantFragment(set('ticket', 'osbd_' + 'a'.repeat(43)))).toBeNull();
		expect(parseGrantFragment(set('exp', 'soon'))).toBeNull();
	});

	it('drop extra parameters from the app link', () => {
		const f = parseGrantFragment(`#${params}&evil=1`);
		expect(f && 'link' in f ? f.link.appUri : null).toBe(appUri);
	});
});
