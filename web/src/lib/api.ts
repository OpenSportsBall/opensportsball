// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0
import type { Device, Game, GameSummary, LinkCode, Me } from './types';

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

	async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
		const token = await opts.getToken();
		if (!token) {
			opts.onUnauthorized();
			throw new ApiError(401, 'unauthorized', 'Your session has expired. Please sign in again.');
		}
		const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
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

		if (res.status === 401) {
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
	return {
		me: () => request<Me>('GET', '/me'),
		createLinkCode: () => request<LinkCode>('POST', '/link-codes'),
		listDevices: async () => (await request<{ devices: Device[] }>('GET', '/devices')).devices,
		unlinkDevice: (deviceId: string) => request<void>('DELETE', `/devices/${enc(deviceId)}`),
		listGames: async () => (await request<{ games: GameSummary[] }>('GET', '/games')).games,
		getGame: (gameId: string) => request<Game>('GET', `/games/${enc(gameId)}`)
	};
}

/** A user-facing sentence for any thrown value. */
export function errorMessage(e: unknown): string {
	if (e instanceof ApiError) return e.message;
	if (e instanceof Error) return e.message;
	return String(e);
}
