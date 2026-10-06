// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it } from 'vitest';
import {
	formatBytes,
	formatCountdown,
	formatDate,
	formatDateTime,
	formatLinkCode,
	formatRelative,
	fraction,
	percent,
	platformLabel,
	roleLabel,
	statusLabel
} from '../src/lib/format.ts';

describe('formatBytes', () => {
	it('uses decimal GB with one decimal', () => {
		expect(formatBytes(20_000_000_000)).toBe('20.0 GB');
		expect(formatBytes(13_000_000_000)).toBe('13.0 GB');
		expect(formatBytes(1_234_567_890)).toBe('1.2 GB');
	});
	it('falls back to MB / KB / B for small sizes', () => {
		expect(formatBytes(512_000_000)).toBe('512 MB');
		expect(formatBytes(2_500)).toBe('3 KB');
		expect(formatBytes(12)).toBe('12 B');
		expect(formatBytes(0)).toBe('0 B');
	});
	it('shows a dash for unknown sizes', () => {
		expect(formatBytes(null)).toBe('—');
		expect(formatBytes(undefined)).toBe('—');
		expect(formatBytes(-1)).toBe('—');
	});
});

describe('formatLinkCode', () => {
	it('inserts the dash', () => expect(formatLinkCode('ABCDEFGH')).toBe('ABCD-EFGH'));
	it('normalises case and stray characters', () => expect(formatLinkCode('abcd-efgh')).toBe('ABCD-EFGH'));
	it('leaves odd lengths alone', () => expect(formatLinkCode('ABC')).toBe('ABC'));
});

describe('progress', () => {
	it('computes fractions and clamps', () => {
		expect(fraction(12, 18)).toBeCloseTo(0.6667, 3);
		expect(fraction(20, 18)).toBe(1);
		expect(fraction(3, null)).toBeNull();
		expect(fraction(3, 0)).toBeNull();
	});
	it('rounds percent down so 99.9% is not shown as done', () => {
		expect(percent(12, 18)).toBe('66%');
		expect(percent(999, 1000)).toBe('99%');
		expect(percent(18, 18)).toBe('100%');
		expect(percent(1, null)).toBe('—');
	});
});

describe('labels', () => {
	it('labels statuses', () => {
		expect(statusLabel('waiting_for_manifest')).toBe('Waiting for manifest');
		expect(statusLabel('uploading')).toBe('Uploading');
		expect(statusLabel('ready')).toBe('Ready');
		expect(statusLabel('something_new')).toBe('something_new');
	});
	it('labels platforms and roles', () => {
		expect(platformLabel('ios')).toBe('iOS');
		expect(platformLabel('android')).toBe('Android');
		expect(roleLabel('main')).toBe('Main camera');
		expect(roleLabel('secondary')).toBe('Second camera');
		expect(roleLabel(null)).toMatch(/not known/);
	});
});

describe('dates', () => {
	it('formats in a given locale and zone', () => {
		expect(formatDate('2026-10-04T17:15:00Z', 'en-US', 'UTC')).toBe('Oct 4, 2026');
		expect(formatDateTime('2026-10-04T17:15:00Z', 'en-US', 'UTC')).toMatch(/Sun, Oct 4, 2026.*5:15/);
	});
	it('handles missing and invalid dates', () => {
		expect(formatDate(null)).toBe('—');
		expect(formatDateTime('not a date')).toBe('—');
	});
	it('formats relative times', () => {
		const now = Date.parse('2026-10-06T12:00:00Z');
		expect(formatRelative(null, now)).toBe('Never');
		expect(formatRelative('2026-10-06T11:59:50Z', now)).toBe('just now');
		expect(formatRelative('2026-10-06T11:55:00Z', now)).toBe('5 minutes ago');
		expect(formatRelative('2026-10-06T11:00:00Z', now)).toBe('1 hour ago');
		expect(formatRelative('2026-10-03T12:00:00Z', now)).toBe('3 days ago');
	});
	it('formats countdowns', () => {
		expect(formatCountdown(600_000)).toBe('10:00');
		expect(formatCountdown(65_400)).toBe('1:06');
		expect(formatCountdown(-5)).toBe('0:00');
	});
});
