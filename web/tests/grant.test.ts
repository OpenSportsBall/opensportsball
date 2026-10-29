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
	it('puts the parameters in the /grant page fragment', () => {
		const url = grantPageUrl('https://site.example/', appUri);
		expect(url).toBe(`https://site.example/grant#${params}`);
		expect(new URL(url).search).toBe('');
	});

	it('reads them back as the app link', () => {
		const url = new URL(grantPageUrl('https://site.example', appUri));
		expect(parseGrantFragment(url.hash)).toEqual({
			apiUrl: 'https://abc.execute-api.us-east-1.amazonaws.com',
			accountId: 'acct-1',
			gameId: 'game-1',
			ticket,
			expiresAt: '2026-11-04T05:00:00.000Z',
			appUri
		});
	});

	it('refuses partial or odd links', () => {
		const without = (k: string) => {
			const p = new URLSearchParams(params);
			p.delete(k);
			return `#${p}`;
		};
		expect(parseGrantFragment('')).toBeNull();
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

	it('drops extra parameters from the app link', () => {
		expect(parseGrantFragment(`#${params}&evil=1`)?.appUri).toBe(appUri);
	});
});
