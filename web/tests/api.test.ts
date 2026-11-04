// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it, vi } from 'vitest';
import { ApiError, createApiClient, errorMessage } from '../src/lib/api.ts';

function setup(respond: (url: string, init: RequestInit) => Response | Promise<Response>, token: string | null = 'tok') {
	const calls: { url: string; init: RequestInit }[] = [];
	const onUnauthorized = vi.fn();
	const client = createApiClient({
		baseUrl: 'https://api.example.com/',
		getToken: async () => token,
		onUnauthorized,
		fetch: (async (url: string, init: RequestInit) => {
			calls.push({ url, init });
			return respond(url, init);
		}) as unknown as typeof fetch
	});
	return { client, calls, onUnauthorized };
}

const json = (status: number, body: unknown) =>
	new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

describe('api client', () => {
	it('sends the bearer token and unwraps list responses', async () => {
		const { client, calls } = setup(() =>
			json(200, { games: [{ gameId: 'g1', createdAt: '2026-10-01T10:00:00Z', recordingCount: 2, status: 'ready' }] })
		);
		const games = await client.listGames();
		expect(games).toHaveLength(1);
		expect(calls[0].url).toBe('https://api.example.com/games');
		expect(calls[0].init.method).toBe('GET');
		expect((calls[0].init.headers as Record<string, string>).Authorization).toBe('Bearer tok');
	});

	it('url-encodes path ids', async () => {
		const { client, calls } = setup(() => json(200, { gameId: 'a/b', createdAt: 'x', recordings: [] }));
		await client.getGame('a/b');
		expect(calls[0].url).toBe('https://api.example.com/games/a%2Fb');
	});

	it('POSTs /link-codes and returns the code', async () => {
		const { client, calls } = setup(() =>
			json(201, { code: 'ABCDEFGH', expiresAt: '2026-10-06T12:10:00Z', linkUri: 'opensportsball://link?v=1' })
		);
		const code = await client.createLinkCode();
		expect(calls[0].init.method).toBe('POST');
		expect(code.code).toBe('ABCDEFGH');
	});

	it('handles 204 from DELETE /devices/{id}', async () => {
		const { client, calls } = setup(() => new Response(null, { status: 204 }));
		await expect(client.unlinkDevice('dev-1')).resolves.toBeUndefined();
		expect(calls[0].init.method).toBe('DELETE');
		expect(calls[0].url).toBe('https://api.example.com/devices/dev-1');
	});

	it('DELETEs the account', async () => {
		const { client, calls } = setup(() => new Response(null, { status: 204 }));
		await expect(client.deleteAccount()).resolves.toBeUndefined();
		expect(calls.map((c) => [c.init.method, c.url])).toEqual([['DELETE', 'https://api.example.com/me']]);
	});

	it('DELETEs a game and a recording', async () => {
		const { client, calls } = setup(() => new Response(null, { status: 204 }));
		await expect(client.deleteGame('g/1')).resolves.toBeUndefined();
		await expect(client.deleteRecording('g1', 'r1')).resolves.toBeUndefined();
		expect(calls.map((c) => [c.init.method, c.url])).toEqual([
			['DELETE', 'https://api.example.com/games/g%2F1'],
			['DELETE', 'https://api.example.com/games/g1/recordings/r1']
		]);
	});

	it('turns {"error","message"} bodies into ApiError', async () => {
		const { client } = setup(() => json(404, { error: 'not_found', message: 'No such game.' }));
		const err = await client.getGame('nope').catch((e) => e);
		expect(err).toBeInstanceOf(ApiError);
		expect(err.status).toBe(404);
		expect(err.code).toBe('not_found');
		expect(err.message).toBe('No such game.');
		expect(errorMessage(err)).toBe('No such game.');
	});

	it('copes with non-JSON error bodies', async () => {
		const { client } = setup(() => new Response('<html>Bad gateway</html>', { status: 502 }));
		const err = await client.listDevices().catch((e) => e);
		expect(err).toBeInstanceOf(ApiError);
		expect(err.code).toBe('http_502');
		expect(err.message).toMatch(/HTTP 502/);
	});

	it('sends the user to sign in on 401', async () => {
		const { client, onUnauthorized } = setup(() => json(401, { error: 'unauthorized', message: 'Token expired' }));
		const err = await client.me().catch((e) => e);
		expect(err.status).toBe(401);
		expect(onUnauthorized).toHaveBeenCalledOnce();
	});

	it('does not call the API without a token', async () => {
		const { client, calls, onUnauthorized } = setup(() => json(200, {}), null);
		await expect(client.me()).rejects.toBeInstanceOf(ApiError);
		expect(calls).toHaveLength(0);
		expect(onUnauthorized).toHaveBeenCalledOnce();
	});

	it('reports network failures plainly', async () => {
		const { client } = setup(() => {
			throw new TypeError('Failed to fetch');
		});
		const err = await client.listGames().catch((e) => e);
		expect(err.code).toBe('network');
		expect(err.message).toMatch(/Could not reach the server/);
	});
});
