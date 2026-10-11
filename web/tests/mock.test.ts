// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it } from 'vitest';
import { createApiClient } from '../src/lib/api.ts';
import { createMockFetch, MOCK_BASE_URL, MOCK_LINK_DELAY_MS } from '../src/lib/mock.ts';

function setup() {
	let t = Date.parse('2026-10-06T12:00:00Z');
	const fetch = createMockFetch({ now: () => t, latencyMs: 0 });
	const api = createApiClient({ baseUrl: MOCK_BASE_URL, getToken: async () => 'mock', onUnauthorized: () => {}, fetch });
	return { api, fetch, advance: (ms: number) => (t += ms) };
}

describe('mock API', () => {
	it('serves games newest first with every status', async () => {
		const { api } = setup();
		const games = await api.listGames();
		expect(games.length).toBeGreaterThanOrEqual(2);
		const times = games.map((g) => g.createdAt);
		expect([...times].sort().reverse()).toEqual(times);
		const recs = (await Promise.all(games.map((g) => api.getGame(g.gameId)))).flatMap((g) => g.recordings);
		expect(new Set(recs.map((r) => r.status))).toEqual(new Set(['waiting_for_manifest', 'uploading', 'ready']));
	});

	it('nulls manifest-only fields before the manifest arrives', async () => {
		const { api } = setup();
		const recs = (await Promise.all((await api.listGames()).map((g) => api.getGame(g.gameId)))).flatMap(
			(g) => g.recordings
		);
		const waiting = recs.find((r) => !r.hasManifest)!;
		expect(waiting.status).toBe('waiting_for_manifest');
		for (const d of waiting.devices) {
			expect(d.role).toBeNull();
			expect(d.expectedSegments).toBeNull();
			expect(d.expectedBytes).toBeNull();
		}
	});

	it('advances uploads over time until ready', async () => {
		const { api, advance } = setup();
		const before = await api.listGames();
		expect(before.some((g) => g.status === 'uploading')).toBe(true);
		advance(60 * 60_000);
		const after = await api.listGames();
		expect(after.some((g) => g.status === 'uploading')).toBe(false);
	});

	it('links a device 5 s after a code is created', async () => {
		const { api, advance } = setup();
		const start = await api.listDevices();
		expect(start).toHaveLength(2);
		const code = await api.createLinkCode();
		expect(code.code).toMatch(/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/);
		expect(code.linkUri).toContain(`code=${code.code}`);
		expect(code.linkUri.startsWith('opensportsball://link?v=1&api=')).toBe(true);
		advance(MOCK_LINK_DELAY_MS - 1000);
		expect(await api.listDevices()).toHaveLength(2);
		advance(2000);
		expect(await api.listDevices()).toHaveLength(3);
	});

	it('unlinks devices and 404s unknown ones', async () => {
		const { api } = setup();
		const [first] = await api.listDevices();
		await api.unlinkDevice(first.deviceId);
		expect((await api.listDevices()).map((d) => d.deviceId)).not.toContain(first.deviceId);
		await expect(api.unlinkDevice(first.deviceId)).rejects.toMatchObject({ status: 404, code: 'not_found' });
		await expect(api.getGame('nope')).rejects.toMatchObject({ status: 404, code: 'not_found' });
	});

	it('requires a bearer token', async () => {
		const { fetch } = setup();
		const res = await fetch(`${MOCK_BASE_URL}/games`);
		expect(res.status).toBe(401);
		expect(await res.json()).toMatchObject({ error: 'unauthorized' });
	});
});
