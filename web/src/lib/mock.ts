// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * In-memory implementation of the people routes in docs/API.md, used when
 * config.json has `"apiUrl": "mock"`. It is a drop-in `fetch`, so the real
 * API client (auth header, error handling) runs unchanged against it.
 *
 * Behaviour worth knowing:
 * - Upload progress advances with wall-clock time, so the game page's
 *   15-second refresh shows bars moving and recordings turning "ready".
 * - A phone "scans" each link code 5 seconds after POST /link-codes: the
 *   next GET /devices after that includes the new device.
 */
import type { Device, Game, GameSummary, LinkCode, Recording, RecordingDevice, RecordingStatus } from './types';

export const MOCK_BASE_URL = 'https://mock.invalid';
export const MOCK_LINK_DELAY_MS = 5_000;
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const CODE_TTL_MS = 10 * 60_000;
const SEGMENT_INTERVAL_MS = 15_000;

interface MockDeviceProgress {
	deviceId: string;
	role: 'main' | 'secondary';
	model: string;
	expectedSegments: number;
	segmentBytes: number;
	/** Segments uploaded when the mock started. */
	startSegments: number;
	/** Segments uploaded per 15 s of wall-clock time. */
	rate: number;
}

interface MockRecording {
	recordingId: string;
	createdAt: string;
	hasManifest: boolean;
	devices: MockDeviceProgress[];
}

interface MockGame {
	gameId: string;
	createdAt: string;
	recordings: MockRecording[];
}

interface PendingCode {
	code: string;
	createdAt: number;
	expiresAt: number;
	used: boolean;
}

export interface MockOptions {
	now?: () => number;
	latencyMs?: number;
	random?: () => number;
}

const IPHONE = 'a3f1c9e2-5b7d-4e08-9c1a-2d6f8b4e7a10';
const PIXEL = 'b7e24d91-0c3a-4f6e-8d25-91c0e3a5f6b2';
const GB = 1e9;

export function createMockFetch(opts: MockOptions = {}): typeof fetch {
	const now = opts.now ?? (() => Date.now());
	const random = opts.random ?? Math.random;
	const latency = opts.latencyMs ?? 250;
	const t0 = now();
	const iso = (ms: number) => new Date(ms).toISOString();
	const ago = (min: number) => iso(t0 - min * 60_000);

	const devices: Device[] = [
		{ deviceId: IPHONE, platform: 'ios', model: 'iPhone 15 Pro', linkedAt: ago(60 * 24 * 21), lastSeenAt: ago(3) },
		{ deviceId: PIXEL, platform: 'android', model: 'Pixel 8', linkedAt: ago(60 * 24 * 20), lastSeenAt: ago(60 * 26) }
	];

	const dev = (
		deviceId: string,
		role: 'main' | 'secondary',
		expectedSegments: number,
		startSegments: number,
		rate: number,
		segmentBytes = 1.12 * GB
	): MockDeviceProgress => ({
		deviceId,
		role,
		model: deviceId === IPHONE ? 'iPhone 15 Pro' : 'Pixel 8',
		expectedSegments,
		segmentBytes,
		startSegments,
		rate
	});

	const games: MockGame[] = [
		{
			gameId: 'g-7f3a9c21-4e6b-4b1d-9a20-5c8e1f0d2b11',
			createdAt: ago(95),
			recordings: [
				{
					recordingId: 'rec-1h-7c2e',
					createdAt: ago(95),
					hasManifest: true,
					devices: [dev(IPHONE, 'main', 9, 4, 1), dev(PIXEL, 'secondary', 9, 6, 1)]
				},
				{
					recordingId: 'rec-2h-91fa',
					createdAt: ago(50),
					hasManifest: false,
					devices: [dev(PIXEL, 'secondary', 9, 1, 0.5)]
				}
			]
		},
		{
			gameId: 'g-1c9e5a07-82d4-4f3a-b6e1-0a7d3c9f4e52',
			createdAt: ago(60 * 24 * 3),
			recordings: [
				{
					recordingId: 'rec-full-3d10',
					createdAt: ago(60 * 24 * 3),
					hasManifest: true,
					devices: [dev(IPHONE, 'main', 18, 12, 1), dev(PIXEL, 'secondary', 18, 14, 1)]
				}
			]
		},
		{
			gameId: 'g-a04b7e3d-6f19-4c82-8d5a-e2b16f7c9a83',
			createdAt: ago(60 * 24 * 7),
			recordings: [
				{
					recordingId: 'rec-1h-55b0',
					createdAt: ago(60 * 24 * 7),
					hasManifest: true,
					devices: [dev(IPHONE, 'main', 9, 9, 0), dev(PIXEL, 'secondary', 9, 9, 0)]
				},
				{
					recordingId: 'rec-2h-e83d',
					createdAt: ago(60 * 24 * 7 - 55),
					hasManifest: true,
					devices: [dev(IPHONE, 'main', 9, 9, 0), dev(PIXEL, 'secondary', 9, 9, 0)]
				}
			]
		}
	];

	const codes: PendingCode[] = [];

	function deviceView(d: MockDeviceProgress, hasManifest: boolean): RecordingDevice {
		const steps = Math.floor((now() - t0) / SEGMENT_INTERVAL_MS);
		const uploaded = Math.min(d.expectedSegments, d.startSegments + Math.floor(steps * d.rate));
		return {
			deviceId: d.deviceId,
			role: hasManifest ? d.role : null,
			model: hasManifest ? d.model : null,
			expectedSegments: hasManifest ? d.expectedSegments : null,
			uploadedSegments: uploaded,
			expectedBytes: hasManifest ? Math.round(d.expectedSegments * d.segmentBytes) : null,
			uploadedBytes: Math.round(uploaded * d.segmentBytes)
		};
	}

	function recordingView(r: MockRecording): Recording {
		const ds = r.devices.map((d) => deviceView(d, r.hasManifest));
		let status: RecordingStatus = 'waiting_for_manifest';
		if (r.hasManifest) {
			status = ds.every((d) => d.uploadedSegments >= (d.expectedSegments ?? Infinity)) ? 'ready' : 'uploading';
		}
		return { recordingId: r.recordingId, createdAt: r.createdAt, status, hasManifest: r.hasManifest, devices: ds };
	}

	const ORDER: RecordingStatus[] = ['waiting_for_manifest', 'uploading', 'ready'];
	function gameView(g: MockGame): Game {
		return { gameId: g.gameId, createdAt: g.createdAt, recordings: g.recordings.map(recordingView) };
	}
	function gameSummary(g: MockGame): GameSummary {
		const recs = gameView(g).recordings;
		const status = recs.reduce<RecordingStatus>(
			(acc, r) => (ORDER.indexOf(r.status) < ORDER.indexOf(acc) ? r.status : acc),
			'ready'
		);
		return { gameId: g.gameId, createdAt: g.createdAt, recordingCount: recs.length, status };
	}

	function uuid(): string {
		const h = () => Math.floor(random() * 16).toString(16);
		const s = (n: number) => Array.from({ length: n }, h).join('');
		return `${s(8)}-${s(4)}-4${s(3)}-a${s(3)}-${s(12)}`;
	}

	/** Pretend a phone scanned every code that is at least 5 s old. */
	function materializeLinks() {
		for (const c of codes) {
			if (c.used || now() < c.createdAt + MOCK_LINK_DELAY_MS || now() > c.expiresAt) continue;
			c.used = true;
			const at = iso(c.createdAt + MOCK_LINK_DELAY_MS);
			devices.push({ deviceId: uuid(), platform: 'android', model: 'Samsung Galaxy S24', linkedAt: at, lastSeenAt: at });
		}
	}

	const json = (status: number, body: unknown) =>
		new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
	const fail = (status: number, error: string, message: string) => json(status, { error, message });

	function route(method: string, path: string): Response {
		let m: RegExpMatchArray | null;
		if (method === 'GET' && path === '/me') {
			return json(200, { accountId: 'mock-account-0001', email: 'parent@example.com' });
		}
		if (method === 'POST' && path === '/link-codes') {
			const code = Array.from({ length: 8 }, () => CODE_ALPHABET[Math.floor(random() * CODE_ALPHABET.length)]).join('');
			const t = now();
			codes.push({ code, createdAt: t, expiresAt: t + CODE_TTL_MS, used: false });
			const body: LinkCode = {
				code,
				expiresAt: iso(t + CODE_TTL_MS),
				linkUri: `opensportsball://link?v=1&api=${encodeURIComponent(MOCK_BASE_URL)}&code=${code}`
			};
			return json(201, body);
		}
		if (method === 'GET' && path === '/devices') {
			materializeLinks();
			return json(200, { devices: devices.map((d) => ({ ...d })) });
		}
		if (method === 'DELETE' && (m = path.match(/^\/devices\/([^/]+)$/))) {
			const id = decodeURIComponent(m[1]);
			const i = devices.findIndex((d) => d.deviceId === id);
			if (i < 0) return fail(404, 'not_found', 'No such device on this account.');
			devices.splice(i, 1);
			return new Response(null, { status: 204 });
		}
		if (method === 'GET' && path === '/games') {
			const list = [...games].sort((a, b) => b.createdAt.localeCompare(a.createdAt)).map(gameSummary);
			return json(200, { games: list });
		}
		if (method === 'GET' && (m = path.match(/^\/games\/([^/]+)$/))) {
			const id = decodeURIComponent(m[1]);
			const g = games.find((x) => x.gameId === id);
			if (!g) return fail(404, 'not_found', 'No such game on this account.');
			return json(200, gameView(g));
		}
		return fail(404, 'not_found', `No route for ${method} ${path} in the mock API.`);
	}

	return async (input, init) => {
		const req = new Request(input, init);
		if (latency > 0) await new Promise((r) => setTimeout(r, latency));
		const auth = req.headers.get('Authorization');
		if (!auth?.startsWith('Bearer ')) return fail(401, 'unauthorized', 'Missing bearer token.');
		const url = new URL(req.url);
		return route(req.method.toUpperCase(), url.pathname);
	};
}
