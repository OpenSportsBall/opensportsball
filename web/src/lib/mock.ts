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
import type {
	AdminAccount,
	AdminAccountGames,
	AdminGame,
	AdminReport,
	Device,
	Game,
	GameSummary,
	GameTicket,
	GrantLookup,
	LinkCode,
	Recording,
	RecordingDevice,
	RecordingStatus
} from './types';

export const MOCK_BASE_URL = 'https://mock.invalid';
export const MOCK_LINK_DELAY_MS = 5_000;
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const CODE_TTL_MS = 10 * 60_000;
const SEGMENT_INTERVAL_MS = 15_000;
const GAME_TICKET_TTL_MS = 7 * 24 * 3600_000;

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
	recordedAt: string | null;
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
					recordedAt: ago(220),
					hasManifest: true,
					devices: [dev(IPHONE, 'main', 9, 4, 1), dev(PIXEL, 'secondary', 9, 6, 1)]
				},
				{
					recordingId: 'rec-2h-91fa',
					createdAt: ago(50),
					recordedAt: null,
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
					recordedAt: ago(60 * 24 * 4),
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
					recordedAt: ago(60 * 24 * 7 + 180),
					hasManifest: true,
					devices: [dev(IPHONE, 'main', 9, 9, 0), dev(PIXEL, 'secondary', 9, 9, 0)]
				},
				{
					recordingId: 'rec-2h-e83d',
					createdAt: ago(60 * 24 * 7 - 55),
					recordedAt: ago(60 * 24 * 7 + 115),
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
		return {
			recordingId: r.recordingId,
			createdAt: r.createdAt,
			recordedAt: r.recordedAt,
			status,
			hasManifest: r.hasManifest,
			devices: ds
		};
	}

	const ORDER: RecordingStatus[] = ['waiting_for_manifest', 'uploading', 'ready'];
	function gameRecordedAt(g: MockGame): string | null {
		const known = g.recordings.flatMap((r) => (r.recordedAt ? [r.recordedAt] : [])).sort();
		return known[0] ?? null;
	}
	function gameView(g: MockGame): Game {
		return {
			gameId: g.gameId,
			createdAt: g.createdAt,
			recordedAt: gameRecordedAt(g),
			recordings: g.recordings.map(recordingView)
		};
	}
	function gameSummary(g: MockGame): GameSummary {
		const recs = gameView(g).recordings;
		const status = recs.length
			? recs.reduce<RecordingStatus>((acc, r) => (ORDER.indexOf(r.status) < ORDER.indexOf(acc) ? r.status : acc), 'ready')
			: null;
		return { gameId: g.gameId, createdAt: g.createdAt, recordedAt: gameRecordedAt(g), recordingCount: recs.length, status };
	}

	function uuid(): string {
		const h = () => Math.floor(random() * 16).toString(16);
		const s = (n: number) => Array.from({ length: n }, h).join('');
		return `${s(8)}-${s(4)}-4${s(3)}-a${s(3)}-${s(12)}`;
	}

	const MOCK_ACCOUNT = 'mock-account-0001';
	const adminEmails: Record<string, string> = {
		[MOCK_ACCOUNT]: 'parent@example.com',
		'mock-account-0002': 'coach.rivera@example.com',
		'mock-account-0003': 'sam.k@example.com',
		'mock-account-0004': 'new.parent@example.com'
	};

	/** [n] games a week apart, each with [recs] recordings of [gb] GB. */
	function sampleGames(prefix: string, n: number, recs: number, gb: number, status: RecordingStatus, daysAgo: number): AdminGame[] {
		return Array.from({ length: n }, (_, i) => {
			const at = ago(60 * 24 * (daysAgo + 7 * i));
			const recordings = Array.from({ length: recs }, (_, j) => ({
				recordingId: `${prefix}-r${i}-${j}`,
				createdAt: at,
				recordedAt: at,
				status,
				hasManifest: status !== 'waiting_for_manifest',
				storageBytes: Math.round(gb * GB),
				objectCount: Math.max(1, Math.round(gb)),
				lastUploadAt: at
			}));
			return {
				gameId: `${prefix}-g${i}`,
				createdAt: at,
				recordedAt: at,
				inTable: true,
				storageBytes: recordings.reduce((sum, r) => sum + r.storageBytes, 0),
				objectCount: recordings.reduce((sum, r) => sum + r.objectCount, 0),
				recordings
			};
		});
	}
	const otherGames = new Map<string, AdminGame[]>([
		['mock-account-0002', sampleGames('rivera', 14, 2, 14.7, 'ready', 2)],
		['mock-account-0003', sampleGames('samk', 1, 1, 3.4, 'waiting_for_manifest', 38)],
		[
			'mock-account-0005',
			[
				{
					gameId: 'orphan-g0',
					createdAt: null,
					recordedAt: null,
					inTable: false,
					storageBytes: 1.1 * GB,
					objectCount: 1,
					recordings: [
						{ recordingId: 'orphan-r0', createdAt: null, recordedAt: null, status: null, hasManifest: false, storageBytes: 1.1 * GB, objectCount: 1, lastUploadAt: ago(60 * 24 * 12) }
					]
				}
			]
		]
	]);

	function adminGames(acct: string): AdminGame[] {
		if (acct !== MOCK_ACCOUNT) return structuredClone(otherGames.get(acct) ?? []);
		return games.map((g) => {
			const recordings = g.recordings.map((r) => {
				const v = recordingView(r);
				return {
					recordingId: r.recordingId,
					createdAt: r.createdAt,
					recordedAt: r.recordedAt,
					status: v.status,
					hasManifest: r.hasManifest,
					storageBytes: v.devices.reduce((n, d) => n + d.uploadedBytes, 0),
					objectCount: v.devices.reduce((n, d) => n + d.uploadedSegments, 0),
					lastUploadAt: v.status === 'ready' ? r.createdAt : ago(1)
				};
			});
			return {
				gameId: g.gameId,
				createdAt: g.createdAt,
				recordedAt: gameRecordedAt(g),
				inTable: true,
				storageBytes: recordings.reduce((n, r) => n + r.storageBytes, 0),
				objectCount: recordings.reduce((n, r) => n + r.objectCount, 0),
				recordings
			};
		});
	}

	/** An account's game, recording and storage totals from its games. */
	function videoTotals(acct: string) {
		const gs = adminGames(acct);
		const recs = gs.flatMap((g) => g.recordings);
		const count = (s: RecordingStatus) => recs.filter((r) => r.status === s).length;
		return {
			// Like the API: only what the table knows counts as games and
			// recordings; footage without a record still counts as storage.
			games: gs.filter((g) => g.inTable).length,
			recordings: { total: recs.filter((r) => r.status !== null).length, waiting_for_manifest: count('waiting_for_manifest'), uploading: count('uploading'), ready: count('ready') },
			storageBytes: gs.reduce((n, g) => n + g.storageBytes, 0),
			objectCount: gs.reduce((n, g) => n + g.objectCount, 0)
		};
	}

	/** The mock user's own row from its games and phones, plus a few
	 *  made-up accounts in other states. */
	function adminReport(): AdminReport {
		materializeLinks();
		const recs = games.flatMap((g) => g.recordings.map(recordingView));
		const segments = recs.flatMap((r) => r.devices);
		const count = (s: RecordingStatus) => recs.filter((r) => r.status === s).length;
		const empty = { total: 0, waiting_for_manifest: 0, uploading: 0, ready: 0 };
		const mine: AdminAccount = {
			accountId: 'mock-account-0001',
			email: 'parent@example.com',
			status: 'active',
			createdAt: ago(60 * 24 * 22),
			devices: devices.map((d) => ({ ...d })),
			games: games.length,
			recordings: { total: recs.length, waiting_for_manifest: count('waiting_for_manifest'), uploading: count('uploading'), ready: count('ready') },
			storageBytes: segments.reduce((n, d) => n + d.uploadedBytes, 0),
			objectCount: segments.reduce((n, d) => n + d.uploadedSegments, 0),
			lastUploadAt: recs.some((r) => r.status !== 'ready') ? ago(1) : ago(60 * 24 * 3),
			oldestObjectAt: ago(60 * 24 * 7)
		};
		const others: AdminAccount[] = [
			{
				accountId: 'mock-account-0002',
				email: 'coach.rivera@example.com',
				status: 'active',
				createdAt: ago(60 * 24 * 160),
				devices: [
					{ deviceId: 'c1d2e3f4-0000-4000-a000-000000000001', platform: 'ios', model: 'iPhone 16', linkedAt: ago(60 * 24 * 158), lastSeenAt: ago(60 * 24 * 2) },
					{ deviceId: 'c1d2e3f4-0000-4000-a000-000000000002', platform: 'ios', model: 'iPhone 13', linkedAt: ago(60 * 24 * 158), lastSeenAt: ago(60 * 24 * 2) }
				],
				games: 14,
				recordings: { ...empty, total: 26, ready: 26 },
				storageBytes: 412.6 * GB,
				objectCount: 372,
				lastUploadAt: ago(60 * 24 * 2),
				oldestObjectAt: ago(60 * 24 * 171)
			},
			{
				accountId: 'mock-account-0003',
				email: 'sam.k@example.com',
				status: 'active',
				createdAt: ago(60 * 24 * 40),
				devices: [{ deviceId: 'c1d2e3f4-0000-4000-a000-000000000003', platform: 'android', model: 'Pixel 9', linkedAt: ago(60 * 24 * 39), lastSeenAt: null }],
				games: 1,
				recordings: { ...empty, total: 1, waiting_for_manifest: 1 },
				storageBytes: 3.4 * GB,
				objectCount: 3,
				lastUploadAt: ago(60 * 24 * 38),
				oldestObjectAt: ago(60 * 24 * 38)
			},
			{
				accountId: 'mock-account-0004',
				email: 'new.parent@example.com',
				status: 'unconfirmed',
				createdAt: ago(30),
				devices: [],
				games: 0,
				recordings: empty,
				storageBytes: 0,
				objectCount: 0,
				lastUploadAt: null,
				oldestObjectAt: null
			},
			{
				accountId: 'mock-account-0005',
				email: null,
				status: 'deleted',
				createdAt: null,
				devices: [],
				games: 0,
				recordings: empty,
				storageBytes: 1.1 * GB,
				objectCount: 1,
				lastUploadAt: ago(60 * 24 * 12),
				oldestObjectAt: ago(60 * 24 * 12)
			}
		];
		const accounts = [mine, ...others]
			.map((a) => ({ ...a, ...videoTotals(a.accountId) }))
			.sort((a, b) => b.storageBytes - a.storageBytes);
		const sum = (f: (a: AdminAccount) => number) => accounts.reduce((n, a) => n + f(a), 0);
		return {
			generatedAt: iso(now()),
			totals: {
				accounts: accounts.filter((a) => a.status !== 'deleted').length,
				deletedAccounts: 3,
				devices: sum((a) => a.devices.length),
				games: sum((a) => a.games),
				recordings: sum((a) => a.recordings.total),
				storageBytes: sum((a) => a.storageBytes),
				objectCount: sum((a) => a.objectCount)
			},
			accounts
		};
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
			return json(200, { accountId: 'mock-account-0001', email: 'parent@example.com', admin: true });
		}
		if (method === 'DELETE' && path === '/me') {
			devices.splice(0);
			games.splice(0);
			codes.splice(0);
			return new Response(null, { status: 204 });
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
		if (method === 'DELETE' && (m = path.match(/^\/games\/([^/]+)$/))) {
			const i = games.findIndex((x) => x.gameId === decodeURIComponent(m![1]));
			if (i < 0) return fail(404, 'not_found', 'No such game.');
			games.splice(i, 1);
			return new Response(null, { status: 204 });
		}
		if (method === 'DELETE' && (m = path.match(/^\/games\/([^/]+)\/recordings\/([^/]+)$/))) {
			const g = games.find((x) => x.gameId === decodeURIComponent(m![1]));
			const i = g?.recordings.findIndex((r) => r.recordingId === decodeURIComponent(m![2])) ?? -1;
			if (!g || i < 0) return fail(404, 'not_found', 'No such recording.');
			g.recordings.splice(i, 1);
			return new Response(null, { status: 204 });
		}
		if (method === 'GET' && path === '/admin/accounts') {
			return json(200, adminReport());
		}
		if (method === 'GET' && (m = path.match(/^\/admin\/accounts\/([^/]+)\/games$/))) {
			const id = decodeURIComponent(m[1]);
			const body: AdminAccountGames = { accountId: id, email: adminEmails[id] ?? null, games: adminGames(id) };
			return json(200, body);
		}
		if (method === 'DELETE' && (m = path.match(/^\/admin\/accounts\/([^/]+)\/games\/([^/]+)(?:\/recordings\/([^/]+))?$/))) {
			const [acct, gameId, recId] = [m[1], m[2], m[3]].map((x) => (x === undefined ? undefined : decodeURIComponent(x)));
			if (acct === MOCK_ACCOUNT) {
				const gi = games.findIndex((g) => g.gameId === gameId);
				if (gi < 0) return fail(404, 'not_found', 'No such game on that account.');
				if (!recId) games.splice(gi, 1);
				else {
					const ri = games[gi].recordings.findIndex((r) => r.recordingId === recId);
					if (ri < 0) return fail(404, 'not_found', 'No such recording on that account.');
					games[gi].recordings.splice(ri, 1);
				}
				return new Response(null, { status: 204 });
			}
			const list = otherGames.get(acct!) ?? [];
			const gi = list.findIndex((g) => g.gameId === gameId);
			if (gi < 0) return fail(404, 'not_found', 'No such game on that account.');
			if (!recId) list.splice(gi, 1);
			else {
				const g = list[gi];
				const ri = g.recordings.findIndex((r) => r.recordingId === recId);
				if (ri < 0) return fail(404, 'not_found', 'No such recording on that account.');
				g.storageBytes -= g.recordings[ri].storageBytes;
				g.objectCount -= g.recordings[ri].objectCount;
				g.recordings.splice(ri, 1);
			}
			return new Response(null, { status: 204 });
		}
		if (method === 'POST' && (m = path.match(/^\/games\/([^/]+)\/grant-tickets$/))) {
			const id = decodeURIComponent(m[1]);
			if (!games.some((x) => x.gameId === id)) return fail(404, 'not_found', 'No such game.');
			const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
			const ticket = 'osbg_' + Array.from({ length: 43 }, () => chars[Math.floor(random() * chars.length)]).join('');
			const expiresAt = iso(now() + GAME_TICKET_TTL_MS);
			const q = new URLSearchParams({ v: '1', api: MOCK_BASE_URL, account: 'mock-account-0001', game: id, ticket, exp: expiresAt });
			const body: GameTicket = {
				ticket,
				apiUrl: MOCK_BASE_URL,
				accountId: 'mock-account-0001',
				gameId: id,
				expiresAt,
				appUri: `opensportsball://grant?${q}`
			};
			gameTickets.set(ticket, body);
			return json(201, body);
		}
		return fail(404, 'not_found', `No route for ${method} ${path} in the mock API.`);
	}

	/** Website tickets made so far, for POST /grants/lookup. */
	const gameTickets = new Map<string, GameTicket>();

	return async (input, init) => {
		const req = new Request(input, init);
		if (latency > 0) await new Promise((r) => setTimeout(r, latency));
		if (req.method === 'POST' && new URL(req.url).pathname === '/grants/lookup') {
			// No sign-in: the /grant page is opened on someone else's phone.
			const { ticket } = (await req.json()) as { ticket?: string };
			const t = ticket ? gameTickets.get(ticket) : undefined;
			if (!t) return fail(404, 'not_found', 'That upload permission does not exist.');
			const body: GrantLookup = { ...t, used: false };
			return json(200, body);
		}
		const auth = req.headers.get('Authorization');
		if (!auth?.startsWith('Bearer ')) return fail(401, 'unauthorized', 'Missing bearer token.');
		const url = new URL(req.url);
		return route(req.method.toUpperCase(), url.pathname);
	};
}
