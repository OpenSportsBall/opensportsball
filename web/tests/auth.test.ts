// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { describe, expect, it, vi } from 'vitest';
import { createSessionReader, type StoredSession } from '../src/lib/auth';

type S = StoredSession & { access_token: string };
const fresh: S = { access_token: 'new', expired: false, expires_in: 3600, refresh_token: 'r' };

describe('createSessionReader', () => {
	it('returns a fresh session without renewing', async () => {
		const renew = vi.fn();
		const read = createSessionReader<S>({ getUser: async () => fresh, renew });
		expect((await read())?.access_token).toBe('new');
		expect(renew).not.toHaveBeenCalled();
	});

	it('is signed out when nothing is stored', async () => {
		const read = createSessionReader<S>({ getUser: async () => null, renew: vi.fn() });
		expect(await read()).toBeNull();
	});

	it('renews an expired session with its refresh token, once for calls made together', async () => {
		const old: S = { access_token: 'old', expired: true, expires_in: -10, refresh_token: 'r' };
		const renew = vi.fn(async () => fresh);
		const read = createSessionReader<S>({ getUser: async () => old, renew });
		const [a, b] = await Promise.all([read(), read()]);
		expect(a?.access_token).toBe('new');
		expect(b?.access_token).toBe('new');
		expect(renew).toHaveBeenCalledTimes(1);
	});

	it('renews a session about to expire, and keeps it if the renewal fails', async () => {
		const closing: S = { access_token: 'old', expired: false, expires_in: 20, refresh_token: 'r' };
		const ok = createSessionReader<S>({ getUser: async () => closing, renew: async () => fresh });
		expect((await ok())?.access_token).toBe('new');
		const failing = createSessionReader<S>({
			getUser: async () => closing,
			renew: async () => {
				throw new Error('offline');
			}
		});
		expect((await failing())?.access_token).toBe('old');
	});

	it('is signed out when an expired session cannot be renewed', async () => {
		const old: S = { access_token: 'old', expired: true, expires_in: -10, refresh_token: 'r' };
		const failing = createSessionReader<S>({
			getUser: async () => old,
			renew: async () => {
				throw new Error('invalid_grant');
			}
		});
		expect(await failing()).toBeNull();
		const none: S = { access_token: 'old', expired: true, expires_in: -10 };
		const renew = vi.fn();
		expect(await createSessionReader<S>({ getUser: async () => none, renew })()).toBeNull();
		expect(renew).not.toHaveBeenCalled();
	});
});
