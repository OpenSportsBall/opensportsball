// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it } from 'vitest';
import { ApiError, createApiClient } from '../src/lib/api.ts';
import { footageByPhone, footagePageUrl, parseFootageFragment } from '../src/lib/footageLink.ts';
import { createMockFetch, MOCK_BASE_URL } from '../src/lib/mock.ts';

const token = 'osbf_' + 'a'.repeat(43);

describe('footage links', () => {
	it('hold only the token, in the fragment', () => {
		const url = footagePageUrl('https://site.example/', token);
		expect(url).toBe(`https://site.example/footage#${token}`);
		expect(new URL(url).search).toBe('');
		expect(parseFootageFragment(new URL(url).hash)).toBe(token);
	});

	it('refuse anything that is not a footage token', () => {
		for (const hash of ['', '#', '#osbf_short', `#osbg_${'a'.repeat(43)}`, `#${token}&x=1`]) {
			expect(parseFootageFragment(hash)).toBeNull();
		}
	});

	it('list files by phone, the main camera first, parts in order', () => {
		const file = (deviceId: string, n: number, bytes: number) => ({
			deviceId,
			fileName: `${deviceId}_00${n}.mp4`,
			bytes,
			sha256: null,
			url: `https://cdn.example/${deviceId}_00${n}.mp4`
		});
		const phones = footageByPhone({
			devices: [
				{ deviceId: 'aaa', role: 'secondary', model: 'Pixel 8' },
				{ deviceId: 'bbb', role: 'main', model: 'iPhone 15 Pro' },
				{ deviceId: 'ccc', role: 'secondary', model: 'Nothing uploaded' }
			],
			files: [file('aaa', 1, 5), file('zzz', 0, 7), file('bbb', 1, 20), file('aaa', 0, 10), file('bbb', 0, 30)]
		});
		expect(phones.map((p) => [p.deviceId, p.model, p.bytes, p.files.map((f) => f.fileName)])).toEqual([
			['bbb', 'iPhone 15 Pro', 50, ['bbb_000.mp4', 'bbb_001.mp4']],
			['aaa', 'Pixel 8', 15, ['aaa_000.mp4', 'aaa_001.mp4']],
			// Uploaded before any manifest named the phone.
			['zzz', null, 7, ['zzz_000.mp4']]
		]);
	});
});

describe('footage links in the mock API', () => {
	function setup() {
		let t = Date.parse('2026-10-06T12:00:00Z');
		const fetch = createMockFetch({ now: () => t, latencyMs: 0 });
		const api = createApiClient({ baseUrl: MOCK_BASE_URL, getToken: async () => 'mock', onUnauthorized: () => {}, fetch });
		// Whoever opens the page has no sign-in at all.
		const visitor = createApiClient({
			baseUrl: MOCK_BASE_URL,
			getToken: async () => null,
			onUnauthorized: () => {
				throw new Error('the /footage page must not ask for a sign-in');
			},
			fetch
		});
		return { api, visitor, advance: (ms: number) => (t += ms) };
	}
	const status = (p: Promise<unknown>) =>
		p.then(
			() => 200,
			(e) => (e as ApiError).status
		);
	async function readyRecording(api: ReturnType<typeof setup>['api']) {
		for (const g of await api.listGames()) {
			const game = await api.getGame(g.gameId);
			const rec = game.recordings.find((r) => r.status === 'ready');
			if (rec) return { gameId: game.gameId, rec };
		}
		throw new Error('the mock has no ready recording');
	}

	it('a page made for a day lists every uploaded file to someone not signed in, until it expires', async () => {
		const { api, visitor, advance } = setup();
		const { gameId, rec } = await readyRecording(api);
		const made = await api.createFootageLink(gameId, rec.recordingId, 24);
		expect(parseFootageFragment(`#${made.token}`)).toBe(made.token);
		expect(await api.listFootageLinks(gameId, rec.recordingId)).toEqual([
			{ linkId: made.linkId, createdAt: made.createdAt, expiresAt: made.expiresAt }
		]);

		const page = await visitor.lookupFootageLink(made.token);
		expect(page.expiresAt).toBe(made.expiresAt);
		expect(Date.parse(page.linksExpireAt)).toBeLessThan(Date.parse(page.expiresAt));
		const phones = footageByPhone(page);
		expect(phones.map((p) => [p.deviceId, p.files.length])).toEqual(
			[...rec.devices]
				.sort((a, b) => (a.role === 'main' ? -1 : b.role === 'main' ? 1 : 0))
				.map((d) => [d.deviceId, d.uploadedSegments])
		);
		expect(phones.reduce((n, p) => n + p.bytes, 0)).toBeCloseTo(rec.devices.reduce((n, d) => n + d.uploadedBytes, 0), -3);

		advance(24 * 3600_000 + 1);
		expect(await status(visitor.lookupFootageLink(made.token))).toBe(410);
		expect(await api.listFootageLinks(gameId, rec.recordingId)).toEqual([]);
	});

	it('stops when its owner stops it, or deletes the recording', async () => {
		const { api, visitor } = setup();
		const { gameId, rec } = await readyRecording(api);
		const a = await api.createFootageLink(gameId, rec.recordingId, 72);
		const b = await api.createFootageLink(gameId, rec.recordingId, 168);
		await api.revokeFootageLink(gameId, rec.recordingId, a.linkId);
		expect(await status(visitor.lookupFootageLink(a.token))).toBe(404);
		expect(await status(visitor.lookupFootageLink(b.token))).toBe(200);
		await api.deleteRecording(gameId, rec.recordingId);
		expect(await status(visitor.lookupFootageLink(b.token))).toBe(404);
	});

	it('only lasts a day, three days or a week', async () => {
		const { api } = setup();
		const { gameId, rec } = await readyRecording(api);
		expect(await status(api.createFootageLink(gameId, rec.recordingId, 8760))).toBe(400);
	});
});
