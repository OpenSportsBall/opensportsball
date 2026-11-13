// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import type {
	AdminAccountGames,
	AdminReport,
	Contribution,
	Device,
	FootageLink,
	FootageLinkCreated,
	FootagePage,
	Game,
	GameSummary,
	GameTicket,
	GrantLookup,
	Job,
	JobQuestions,
	CheckAnswer,
	JobVideo,
	LinkCode,
	Me
} from './types';

/** An API failure: HTTP status plus the `{"error","message"}` body (docs/API.md). */
export class ApiError extends Error {
	constructor(
		readonly status: number,
		readonly code: string,
		message: string
	) {
		super(message);
		this.name = 'ApiError';
	}
}

export interface ApiClientOptions {
	baseUrl: string;
	/** Returns the current access token, or null when signed out / expired. */
	getToken: () => Promise<string | null>;
	/** Called on 401 or a missing token; normally redirects to sign in. */
	onUnauthorized: () => void;
	fetch?: typeof fetch;
}

export type ApiClient = ReturnType<typeof createApiClient>;

export function createApiClient(opts: ApiClientOptions) {
	const doFetch = opts.fetch ?? ((...a: Parameters<typeof fetch>) => fetch(...a));
	const base = opts.baseUrl.replace(/\/+$/, '');

	/** [anonymous]: a route that needs no sign-in (the /grant and /footage pages). */
	async function request<T>(method: string, path: string, body?: unknown, anonymous = false): Promise<T> {
		const headers: Record<string, string> = {};
		if (!anonymous) {
			const token = await opts.getToken();
			if (!token) {
				opts.onUnauthorized();
				throw new ApiError(401, 'unauthorized', 'Your session has expired. Please sign in again.');
			}
			headers.Authorization = `Bearer ${token}`;
		}
		if (body !== undefined) headers['Content-Type'] = 'application/json';

		let res: Response;
		try {
			res = await doFetch(`${base}${path}`, {
				method,
				headers,
				body: body === undefined ? undefined : JSON.stringify(body)
			});
		} catch {
			throw new ApiError(0, 'network', 'Could not reach the server. Check your connection and try again.');
		}

		if (res.status === 401 && !anonymous) {
			opts.onUnauthorized();
			throw new ApiError(401, 'unauthorized', 'Your session has expired. Please sign in again.');
		}
		if (res.status === 204) return undefined as T;

		const text = await res.text();
		let data: unknown = undefined;
		if (text) {
			try {
				data = JSON.parse(text);
			} catch {
				data = undefined;
			}
		}
		if (!res.ok) {
			const err = data as { error?: unknown; message?: unknown } | undefined;
			const code = typeof err?.error === 'string' ? err.error : 'http_' + res.status;
			const message =
				typeof err?.message === 'string' && err.message
					? err.message
					: `The server returned an error (HTTP ${res.status}).`;
			throw new ApiError(res.status, code, message);
		}
		if (data === undefined) {
			throw new ApiError(res.status, 'bad_response', 'The server sent a response this page could not read.');
		}
		return data as T;
	}

	const enc = encodeURIComponent;
	const jobs = (gameId: string, recordingId: string) => `/games/${enc(gameId)}/recordings/${enc(recordingId)}/jobs`;
	const footageLinks = (gameId: string, recordingId: string) =>
		`/games/${enc(gameId)}/recordings/${enc(recordingId)}/footage-links`;
	const job = (j: Pick<Job, 'gameId' | 'recordingId' | 'jobId'>) => `${jobs(j.gameId, j.recordingId)}/${enc(j.jobId)}`;
	return {
		me: () => request<Me>('GET', '/me'),
		/** Deletes the account, its phones, games and footage, and its sign-in, for good. */
		deleteAccount: () => request<void>('DELETE', '/me'),
		createLinkCode: () => request<LinkCode>('POST', '/link-codes'),
		listDevices: async () => (await request<{ devices: Device[] }>('GET', '/devices')).devices,
		unlinkDevice: (deviceId: string) => request<void>('DELETE', `/devices/${enc(deviceId)}`),
		listGames: async () => (await request<{ games: GameSummary[] }>('GET', '/games')).games,
		getGame: (gameId: string) => request<Game>('GET', `/games/${enc(gameId)}`),
		/** Deletes the game, every recording in it and their footage, for good. */
		deleteGame: (gameId: string) => request<void>('DELETE', `/games/${enc(gameId)}`),
		/** Deletes one recording and its footage, for good. */
		deleteRecording: (gameId: string, recordingId: string) =>
			request<void>('DELETE', `/games/${enc(gameId)}/recordings/${enc(recordingId)}`),
		createGameTicket: (gameId: string) => request<GameTicket>('POST', `/games/${enc(gameId)}/grant-tickets`),
		/** What the account shared to improve the models (pitch maps, kit groups, labels). */
		listContributions: async () =>
			(await request<{ contributions: Contribution[] }>('GET', '/contributions')).contributions,
		/** Withdraws a shared result: its files are deleted, for good. */
		withdrawContribution: (contributionId: string) =>
			request<void>('DELETE', `/contributions/${enc(contributionId)}`),
		/** Every account, for admins only (403 otherwise). */
		adminAccounts: () => request<AdminReport>('GET', '/admin/accounts'),
		/** One account's games and recordings with their footage (admins). */
		adminAccountGames: (accountId: string) =>
			request<AdminAccountGames>('GET', `/admin/accounts/${enc(accountId)}/games`),
		/** Deletes any account's game and its footage, for good (admins). */
		adminDeleteGame: (accountId: string, gameId: string) =>
			request<void>('DELETE', `/admin/accounts/${enc(accountId)}/games/${enc(gameId)}`),
		/** Deletes any account's recording and its footage, for good (admins). */
		adminDeleteRecording: (accountId: string, gameId: string, recordingId: string) =>
			request<void>('DELETE', `/admin/accounts/${enc(accountId)}/games/${enc(gameId)}/recordings/${enc(recordingId)}`),
		/** Starts processing a ready recording in the cloud. */
		startJob: (gameId: string, recordingId: string) => request<Job>('POST', jobs(gameId, recordingId), { where: 'cloud' }),
		getJob: (gameId: string, recordingId: string, jobId: string) =>
			request<Job>('GET', job({ gameId, recordingId, jobId })),
		cancelJob: (j: Job) => request<void>('DELETE', job(j)),
		/** The engine's questions (cameras, pitch), with links to their pictures. */
		jobQuestions: (j: Job) => request<JobQuestions>('GET', `${job(j)}/questions`),
		/** Answers one of the engine's questions (cameras or pitch). */
		answerCheck: (j: Job, answer: CheckAnswer) => request<Job>('PUT', `${job(j)}/answers`, answer),
		/** A signed link to the finished game video. */
		jobVideo: (j: Job) => request<JobVideo>('POST', `${job(j)}/downloads`),
		/** Lets an account process in the cloud, or stops it (admins). */
		adminSetCloudProcessing: (accountId: string, enabled: boolean) =>
			request<{ accountId: string; cloudProcessing: boolean }>('PUT', `/admin/accounts/${enc(accountId)}/cloud-processing`, {
				enabled
			}),
		/** The recording's download pages that still work. */
		listFootageLinks: async (gameId: string, recordingId: string) =>
			(await request<{ links: FootageLink[] }>('GET', footageLinks(gameId, recordingId))).links,
		/** A page of download links to the recording's raw video, for [hours] (24, 72 or 168). */
		createFootageLink: (gameId: string, recordingId: string, hours: number) =>
			request<FootageLinkCreated>('POST', footageLinks(gameId, recordingId), { hours }),
		/** Stops a download page working. */
		revokeFootageLink: (gameId: string, recordingId: string, linkId: string) =>
			request<void>('DELETE', `${footageLinks(gameId, recordingId)}/${enc(linkId)}`),
		lookupFootageLink: (token: string) => request<FootagePage>('POST', '/footage-links/lookup', { token }, true),
		lookupGrantTicket: (ticket: string) => request<GrantLookup>('POST', '/grants/lookup', { ticket }, true)
	};
}

/** A user-facing sentence for any thrown value. */
export function errorMessage(e: unknown): string {
	if (e instanceof ApiError) return e.message;
	if (e instanceof Error) return e.message;
	return String(e);
}
