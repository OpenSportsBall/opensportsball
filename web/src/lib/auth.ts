// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Sign-in: Cognito hosted login, authorization code + PKCE (oidc-client-ts).
 * The access token lasts an hour; when it is about to run out it is renewed
 * with the refresh token, with no redirect, for as long as the refresh token
 * lasts (refreshTokenValidity of the Web client in infra/lib/stack.ts). After
 * that the user is sent through the hosted login again. In mock mode there is
 * no Cognito at all.
 */
import { UserManager, WebStorageStateStore, type User } from 'oidc-client-ts';
import type { SiteConfig } from './types';

export interface Auth {
	readonly mock: boolean;
	/** True when there is a stored session that is unexpired or could be renewed. */
	isSignedIn(): Promise<boolean>;
	/** The access token (renewed if need be), or null when signed out or expired for good. */
	getToken(): Promise<string | null>;
	/** Email from the ID token, if known (the header prefers GET /me). */
	email(): Promise<string | null>;
	/** Redirects to the hosted login; comes back to `returnTo`. */
	signIn(returnTo?: string): Promise<void>;
	/** Completes the redirect on /callback; returns where to go next. */
	handleCallback(): Promise<string>;
	signOut(): Promise<void>;
}

/** Only same-site paths, never "//evil.example" or absolute URLs. */
export function safeReturnTo(value: unknown): string {
	if (typeof value !== 'string' || !value.startsWith('/') || value.startsWith('//') || value.startsWith('/\\')) {
		return '/games';
	}
	if (value === '/' || value.startsWith('/callback')) return '/games';
	return value;
}

export function currentPath(): string {
	return window.location.pathname + window.location.search;
}

/** The parts of a stored session that [createSessionReader] looks at. */
export interface StoredSession {
	expired?: boolean;
	/** Seconds until the access token expires. */
	expires_in?: number;
	refresh_token?: string;
}

/** Renew this long before the access token expires, so a request never carries one about to lapse. */
const RENEW_BEFORE_SECONDS = 60;

/**
 * Returns a function giving the current session, renewed with its refresh
 * token when the access token has expired or is about to; null when signed
 * out. Calls made while a renewal is running share it. If the renewal fails
 * (refresh token expired or revoked, or no network) the old session is still
 * returned until its access token actually expires.
 */
export function createSessionReader<U extends StoredSession>(source: {
	getUser(): Promise<U | null>;
	renew(): Promise<U | null>;
}): () => Promise<U | null> {
	let renewing: Promise<U | null> | null = null;
	return async () => {
		const user = await source.getUser();
		if (!user) return null;
		const fresh = !user.expired && (user.expires_in ?? 0) > RENEW_BEFORE_SECONDS;
		if (fresh) return user;
		if (user.refresh_token) {
			renewing ??= source
				.renew()
				.catch(() => null)
				.finally(() => {
					renewing = null;
				});
			const renewed = await renewing;
			if (renewed && !renewed.expired) return renewed;
		}
		return user.expired ? null : user;
	};
}

export function createCognitoAuth(config: SiteConfig): Auth {
	const issuer = `https://cognito-idp.${config.region}.amazonaws.com/${config.userPoolId}`;
	const domain = config.cognitoDomain;
	const origin = window.location.origin;

	const manager = new UserManager({
		authority: issuer,
		client_id: config.userPoolClientId,
		redirect_uri: `${origin}/callback`,
		response_type: 'code',
		scope: 'openid email',
		// Cognito's discovery document has no end_session_endpoint and lives on
		// a different host than the hosted UI, so spell the endpoints out.
		metadata: {
			issuer,
			authorization_endpoint: `${domain}/oauth2/authorize`,
			token_endpoint: `${domain}/oauth2/token`,
			userinfo_endpoint: `${domain}/oauth2/userInfo`,
			revocation_endpoint: `${domain}/oauth2/revoke`,
			end_session_endpoint: `${domain}/logout`,
			jwks_uri: `${issuer}/.well-known/jwks.json`
		},
		userStore: new WebStorageStateStore({ store: window.localStorage }),
		automaticSilentRenew: false,
		monitorSession: false,
		loadUserInfo: false
	});

	let redirecting = false;
	// With a refresh token stored, signinSilent() asks the token endpoint for
	// new tokens; no iframe, no redirect.
	const validUser = createSessionReader<User>({
		getUser: () => manager.getUser(),
		renew: () => manager.signinSilent()
	});

	return {
		mock: false,
		async isSignedIn() {
			return (await validUser()) !== null;
		},
		async getToken() {
			return (await validUser())?.access_token ?? null;
		},
		async email() {
			const email = (await validUser())?.profile.email;
			return typeof email === 'string' ? email : null;
		},
		async signIn(returnTo = currentPath()) {
			if (redirecting) return;
			redirecting = true;
			await manager.removeUser();
			await manager.signinRedirect({ state: { returnTo: safeReturnTo(returnTo) } });
		},
		async handleCallback() {
			const user = await manager.signinCallback();
			const state = user?.state as { returnTo?: unknown } | undefined;
			return safeReturnTo(state?.returnTo);
		},
		async signOut() {
			await manager.removeUser();
			const params = new URLSearchParams({ client_id: config.userPoolClientId, logout_uri: `${origin}/` });
			window.location.assign(`${domain}/logout?${params}`);
		}
	};
}

const MOCK_SIGNED_OUT = 'osb-mock-signed-out';

function readFlag(): boolean {
	try {
		return window.sessionStorage.getItem(MOCK_SIGNED_OUT) === '1';
	} catch {
		return false;
	}
}
function writeFlag(signedOut: boolean) {
	try {
		if (signedOut) window.sessionStorage.setItem(MOCK_SIGNED_OUT, '1');
		else window.sessionStorage.removeItem(MOCK_SIGNED_OUT);
	} catch {
		/* storage blocked: mock just stays signed in */
	}
}

/** Fake signed-in user for `"apiUrl": "mock"`. Sign out / in toggle a flag. */
export function createMockAuth(): Auth {
	return {
		mock: true,
		async isSignedIn() {
			return !readFlag();
		},
		async getToken() {
			return readFlag() ? null : 'mock-access-token';
		},
		async email() {
			return readFlag() ? null : 'parent@example.com';
		},
		async signIn(returnTo = currentPath()) {
			writeFlag(false);
			window.location.assign(`/callback?mock=1&returnTo=${encodeURIComponent(safeReturnTo(returnTo))}`);
		},
		async handleCallback() {
			return safeReturnTo(new URLSearchParams(window.location.search).get('returnTo'));
		},
		async signOut() {
			writeFlag(true);
			window.location.assign('/');
		}
	};
}
