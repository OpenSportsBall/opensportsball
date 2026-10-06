// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it } from 'vitest';
import { loadConfig, parseConfig } from '../src/lib/config.ts';
import { safeReturnTo } from '../src/lib/auth.ts';

const good = {
	apiUrl: 'https://abc.execute-api.us-east-1.amazonaws.com/',
	region: 'us-east-1',
	userPoolId: 'us-east-1_X',
	userPoolClientId: 'client',
	cognitoDomain: 'https://x.auth.us-east-1.amazoncognito.com/'
};

describe('config', () => {
	it('accepts a full config and trims trailing slashes', () => {
		const c = parseConfig(good);
		expect(c.apiUrl).toBe('https://abc.execute-api.us-east-1.amazonaws.com');
		expect(c.cognitoDomain).toBe('https://x.auth.us-east-1.amazoncognito.com');
	});
	it('names missing keys', () => {
		expect(() => parseConfig({ apiUrl: 'https://x' })).toThrow(/region, userPoolId, userPoolClientId, cognitoDomain/);
	});
	it('needs only apiUrl in mock mode', () => {
		expect(parseConfig({ apiUrl: 'mock' }).apiUrl).toBe('mock');
	});
	it('reports a missing config.json', async () => {
		const f = (async () => new Response('nope', { status: 404 })) as unknown as typeof fetch;
		await expect(loadConfig(f)).rejects.toThrow(/HTTP 404/);
	});
});

describe('safeReturnTo', () => {
	it('keeps same-site paths', () => expect(safeReturnTo('/game?id=abc')).toBe('/game?id=abc'));
	it('rejects open redirects', () => {
		expect(safeReturnTo('https://evil.example')).toBe('/games');
		expect(safeReturnTo('//evil.example')).toBe('/games');
		expect(safeReturnTo('/\\evil.example')).toBe('/games');
		expect(safeReturnTo(undefined)).toBe('/games');
	});
	it('does not return to / or /callback', () => {
		expect(safeReturnTo('/')).toBe('/games');
		expect(safeReturnTo('/callback?code=1')).toBe('/games');
	});
});
