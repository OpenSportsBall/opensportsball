// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import type { Job, RecordingStatus } from './types';

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

/** When a game or recording was recorded, or when its first upload arrived
 *  while that is not known yet. */
export const recordedTime = (x: { createdAt: string; recordedAt: string | null }) => x.recordedAt ?? x.createdAt;

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

const STAGE_LABELS: Record<string, string> = {
	sync: 'Lining up the two phones',
	pitch: 'Finding the pitch',
	kits: 'Sorting the kits',
	ball: 'Finding the ball',
	roles: 'Finding the players',
	render: 'Making the video',
	upload: 'Saving the video'
};

/** What a job is doing, for a person. */
export function jobHeadline(job: Pick<Job, 'status' | 'phase' | 'where' | 'progress'>): string {
	const local = job.where === 'local';
	switch (job.status) {
		case 'queued':
			return job.phase === 'run' ? 'Waiting for a machine to make the video' : 'Waiting for a machine';
		case 'preparing':
			return local ? 'Getting ready on your computer' : 'Getting the game ready for your checks';
		case 'needs_answers':
			return local ? 'Waiting for your checks in the app' : 'Waiting for your checks';
		case 'refitting':
			return 'Redoing a check from your answer';
		case 'running':
			return local ? 'Processing on your computer' : 'Making the video';
		case 'done':
			return 'Video ready';
		case 'failed':
			return 'Processing failed';
		case 'cancelled':
			return 'Processing cancelled';
	}
}

export const stageLabel = (stage: string) => STAGE_LABELS[stage] ?? stage;

/** "about 2 hours left", "about 5 minutes left"; "" when unknown. */
export function formatEta(seconds: number | null | undefined): string {
	if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return '';
	if (seconds < 90) return 'about a minute left';
	if (seconds < 5400) return `about ${Math.round(seconds / 60)} minutes left`;
	const h = Math.round(seconds / 3600);
	return `about ${h} hour${h === 1 ? '' : 's'} left`;
}

export const jobIsActive = (job: Pick<Job, 'status'> | null | undefined) =>
	job != null && !['done', 'failed', 'cancelled'].includes(job.status);
