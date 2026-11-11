// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import { createApiClient, errorMessage, type ApiClient } from './api';
import { createCognitoAuth, createMockAuth, currentPath, type Auth } from './auth';
import { isMock, loadConfig } from './config';
import type { SiteConfig } from './types';

/** App-wide state: config, auth and the API client, set up once at startup. */
class Session {
	status = $state<'loading' | 'ready' | 'error'>('loading');
	error = $state<string | null>(null);
	signedIn = $state(false);
	email = $state<string | null>(null);
	/** From GET /me; shows the Admin link. The API checks it again. */
	admin = $state(false);
	/** From GET /me: an admin has switched cloud processing on for this account. */
	cloudProcessing = $state(false);
	config = $state<SiteConfig | null>(null);
	/** True when config.json says `"apiUrl": "mock"`. */
	mock = $state(false);
	auth: Auth | null = null;
	#api: ApiClient | null = null;
	#started: Promise<void> | null = null;

	get api(): ApiClient {
		if (!this.#api) throw new Error('The site is still starting up.');
		return this.#api;
	}

	init(): Promise<void> {
		this.#started ??= this.#init();
		return this.#started;
	}

	async #init() {
		try {
			const config = await loadConfig();
			this.config = config;
			let apiFetch: typeof fetch | undefined;
			let baseUrl = config.apiUrl;
			if (isMock(config)) {
				const mock = await import('./mock');
				apiFetch = mock.createMockFetch();
				baseUrl = mock.MOCK_BASE_URL;
				this.auth = createMockAuth();
				this.mock = true;
			} else {
				this.auth = createCognitoAuth(config);
			}
			const auth = this.auth;
			this.#api = createApiClient({
				baseUrl,
				fetch: apiFetch,
				getToken: () => auth.getToken(),
				onUnauthorized: () => void auth.signIn(currentPath())
			});
			this.signedIn = await auth.isSignedIn();
			this.email = await auth.email();
			this.status = 'ready';
			if (this.signedIn) void this.#loadMe();
		} catch (e) {
			this.error = errorMessage(e);
			this.status = 'error';
		}
	}

	async #loadMe() {
		try {
			const me = await this.api.me();
			this.email = me.email || this.email;
			this.admin = me.admin === true;
			this.cloudProcessing = me.cloudProcessing === true;
		} catch {
			/* header falls back to the ID-token email; pages show their own errors */
		}
	}

	signIn(returnTo?: string) {
		return this.auth?.signIn(returnTo);
	}

	signOut() {
		return this.auth?.signOut();
	}

	/** Pages that need an account call this; it redirects to sign in if needed. */
	async requireSignIn(): Promise<boolean> {
		await this.init();
		if (this.status !== 'ready') return false;
		if (await this.auth!.isSignedIn()) return true;
		this.signedIn = false;
		await this.auth!.signIn(currentPath());
		return false;
	}
}

export const session = new Session();
