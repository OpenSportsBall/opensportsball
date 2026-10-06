// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0
import type { SiteConfig } from './types';

const KEYS = ['apiUrl', 'region', 'userPoolId', 'userPoolClientId', 'cognitoDomain'] as const;

export function isMock(config: SiteConfig): boolean {
	return config.apiUrl === 'mock';
}

/** Validates the parsed /config.json; throws a readable error when it is wrong. */
export function parseConfig(raw: unknown): SiteConfig {
	if (!raw || typeof raw !== 'object') throw new Error('config.json is not a JSON object.');
	const obj = raw as Record<string, unknown>;
	if (obj.apiUrl === 'mock') {
		return {
			apiUrl: 'mock',
			region: String(obj.region ?? 'mock'),
			userPoolId: String(obj.userPoolId ?? 'mock'),
			userPoolClientId: String(obj.userPoolClientId ?? 'mock'),
			cognitoDomain: String(obj.cognitoDomain ?? 'mock')
		};
	}
	const missing = KEYS.filter((k) => typeof obj[k] !== 'string' || obj[k] === '');
	if (missing.length) throw new Error(`config.json is missing: ${missing.join(', ')}.`);
	const config = Object.fromEntries(KEYS.map((k) => [k, obj[k] as string])) as unknown as SiteConfig;
	config.apiUrl = config.apiUrl.replace(/\/+$/, '');
	config.cognitoDomain = config.cognitoDomain.replace(/\/+$/, '');
	return config;
}

/** Fetches the deployment config. Nothing deployment-specific is compiled in. */
export async function loadConfig(fetchFn: typeof fetch = fetch): Promise<SiteConfig> {
	let res: Response;
	try {
		res = await fetchFn('/config.json', { cache: 'no-store' });
	} catch {
		throw new Error('Could not load /config.json (network error).');
	}
	if (!res.ok) throw new Error(`Could not load /config.json (HTTP ${res.status}).`);
	let raw: unknown;
	try {
		raw = await res.json();
	} catch {
		throw new Error('/config.json is not valid JSON.');
	}
	return parseConfig(raw);
}
