// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0
import type { RecordingStatus } from './types';

/** Decimal units, matching what phones show for storage. */
export function formatBytes(bytes: number | null | undefined): string {
	if (bytes == null || !Number.isFinite(bytes) || bytes < 0) return '—';
	if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(1)} GB`;
	if (bytes >= 1e6) return `${Math.round(bytes / 1e6)} MB`;
	if (bytes >= 1e3) return `${Math.round(bytes / 1e3)} KB`;
	return `${bytes} B`;
}

/** "ABCDEFGH" -> "ABCD-EFGH" for people to type. */
export function formatLinkCode(code: string): string {
	const c = code.replace(/[^A-Za-z0-9]/g, '').toUpperCase();
	return c.length === 8 ? `${c.slice(0, 4)}-${c.slice(4)}` : c;
}

/** Fraction done in [0, 1], or null when the expected total is unknown. */
export function fraction(done: number, total: number | null | undefined): number | null {
	if (total == null || total <= 0) return null;
	return Math.min(1, Math.max(0, done / total));
}

export function percent(done: number, total: number | null | undefined): string {
	const f = fraction(done, total);
	return f == null ? '—' : `${Math.floor(f * 100)}%`;
}

export const STATUS_LABELS: Record<RecordingStatus, string> = {
	waiting_for_manifest: 'Waiting for manifest',
	uploading: 'Uploading',
	ready: 'Ready'
};

export function statusLabel(status: string): string {
	return STATUS_LABELS[status as RecordingStatus] ?? status;
}

export function platformLabel(platform: string): string {
	if (platform === 'ios') return 'iOS';
	if (platform === 'android') return 'Android';
	return platform;
}

export function roleLabel(role: string | null): string {
	if (role === 'main') return 'Main camera';
	if (role === 'secondary') return 'Second camera';
	return 'Role not known yet';
}

function toDate(iso: string): Date | null {
	const d = new Date(iso);
	return Number.isNaN(d.getTime()) ? null : d;
}

/** "Sat, Oct 4, 2026, 10:15 AM" in the viewer's time zone. */
export function formatDateTime(iso: string | null | undefined, locale?: string, timeZone?: string): string {
	const d = iso ? toDate(iso) : null;
	if (!d) return '—';
	return d.toLocaleString(locale, {
		weekday: 'short',
		month: 'short',
		day: 'numeric',
		year: 'numeric',
		hour: 'numeric',
		minute: '2-digit',
		timeZone
	});
}

export function formatDate(iso: string | null | undefined, locale?: string, timeZone?: string): string {
	const d = iso ? toDate(iso) : null;
	if (!d) return '—';
	return d.toLocaleDateString(locale, { month: 'short', day: 'numeric', year: 'numeric', timeZone });
}

/** "just now", "5 minutes ago", "3 days ago"; "Never" for null. */
export function formatRelative(iso: string | null | undefined, now: number = Date.now()): string {
	if (!iso) return 'Never';
	const d = toDate(iso);
	if (!d) return '—';
	const sec = Math.round((now - d.getTime()) / 1000);
	if (sec < 45) return 'just now';
	const units: [number, string][] = [
		[60, 'minute'],
		[3600, 'hour'],
		[86400, 'day'],
		[86400 * 30, 'month'],
		[86400 * 365, 'year']
	];
	let pick = units[0];
	for (const u of units) if (sec >= u[0]) pick = u;
	const n = Math.max(1, Math.round(sec / pick[0]));
	return `${n} ${pick[1]}${n === 1 ? '' : 's'} ago`;
}

/** Remaining time as "m:ss"; "0:00" once past. */
export function formatCountdown(msLeft: number): string {
	const s = Math.max(0, Math.ceil(msLeft / 1000));
	return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

export function shortId(id: string): string {
	return id.length > 8 ? id.slice(0, 8) : id;
}
