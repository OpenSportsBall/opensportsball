// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it } from 'vitest';
import { ApiError, createApiClient } from '../src/lib/api.ts';
import { formatEta, jobHeadline, jobIsActive } from '../src/lib/format.ts';
import { createMockFetch, MOCK_BASE_URL, MOCK_JOB_MS } from '../src/lib/mock.ts';
import type { Job } from '../src/lib/types.ts';

function setup() {
	let t = Date.parse('2026-11-10T12:00:00Z');
	const fetch = createMockFetch({ now: () => t, latencyMs: 0 });
	const api = createApiClient({ baseUrl: MOCK_BASE_URL, getToken: async () => 'mock', onUnauthorized: () => {}, fetch });
	return { api, advance: (ms: number) => (t += ms) };
}

/** The mock's oldest game: both recordings ready, the first already processed. */
const GAME = 'g-a04b7e3d-6f19-4c82-8d5a-e2b16f7c9a83';
const FRESH = 'rec-2h-e83d';
const refuses = (status: number) => (e: unknown) => e instanceof ApiError && e.status === status;

describe('processing a game in the cloud (mock API)', () => {
	it('shows each recording with its newest job', async () => {
		const { api } = setup();
		const game = await api.getGame(GAME);
		const [first, second] = [...game.recordings].sort((a, b) => a.recordingId.localeCompare(b.recordingId));
		expect(first.job).toMatchObject({ status: 'done', phase: 'run', where: 'cloud' });
		expect(second.job).toBeNull();
		expect((await api.me()).cloudProcessing).toBe(true);
	});

	it('walks from the button to the video through both checks', async () => {
		const { api, advance } = setup();
		const reload = (j: Job) => api.getJob(j.gameId, j.recordingId, j.jobId);

		let job = await api.startJob(GAME, FRESH);
		expect(job).toMatchObject({ status: 'queued', phase: 'prepare', checks: { pitch: 'open', kits: 'open' } });
		await expect(api.startJob(GAME, FRESH)).rejects.toSatisfy(refuses(409));
		await expect(api.jobQuestions(job)).rejects.toSatisfy(refuses(409));

		advance(MOCK_JOB_MS.queue + MOCK_JOB_MS.prepare / 2);
		job = await reload(job);
		expect(job.status).toBe('preparing');
		expect(job.progress!.fraction).toBeCloseTo(0.5, 1);

		advance(MOCK_JOB_MS.prepare);
		job = await reload(job);
		expect(job.status).toBe('needs_answers');
		expect((await api.getGame(GAME)).recordings.find((r) => r.recordingId === FRESH)!.job!.status).toBe('needs_answers');

		// The pitch: the first fit is off, so a point is moved and it is asked again.
		let q = (await api.jobQuestions(job)).questions;
		expect(q.pending).toEqual(['pitch', 'kits']);
		let pitch = q.pitch!;
		expect(pitch.round).toBe(1);
		expect(pitch.overlayUrl).toMatch(/^data:image\/svg\+xml,/);
		expect(pitch.backgroundUrl).toMatch(/^data:image\/svg\+xml,/);
		expect(pitch.panorama).toMatchObject({ degPerPx: 0.1, yawRange: [-100, 100] });
		expect(pitch.lines.length).toBeGreaterThan(3);
		// The engine works in panorama degrees: the far right corner really is at pixel (1480, 250).
		const corner = { yaw: -100 + 1480 * 0.1, pitch: -20 + 250 * 0.1 };
		expect(pitch.points['far right corner flag']).not.toEqual(corner);
		job = await api.answerCheck(job, {
			question: 'pitch',
			round: 1,
			points: { 'far right corner flag': corner, 'halfway far end': { skipped: true }, 'left corner flag': { fromFit: true } }
		});
		expect(job.status).toBe('refitting');
		await expect(api.answerCheck(job, { question: 'pitch', round: 1, approve: true })).rejects.toSatisfy(refuses(409));
		advance(MOCK_JOB_MS.refit);
		job = await reload(job);
		expect(job).toMatchObject({ status: 'needs_answers', checks: { pitch: 'open', kits: 'open' } });
		q = (await api.jobQuestions(job)).questions;
		pitch = q.pitch!;
		expect(pitch.round).toBe(2);
		expect(pitch.points['far right corner flag']).toEqual(corner);
		// An answer to the old drawing is refused; the new one is approved.
		await expect(api.answerCheck(job, { question: 'pitch', round: 1, approve: true })).rejects.toSatisfy(refuses(409));
		job = await api.answerCheck(job, { question: 'pitch', round: 2, approve: true });
		expect(job).toMatchObject({ status: 'needs_answers', checks: { pitch: 'answered', kits: 'open' } });

		// The kits: one group is two kits, so it is split and shown again, once.
		let kits = q.kits!;
		expect(kits.groups.map((g) => [g.component, g.proposed])).toEqual([
			[0, 'A'],
			[1, 'B'],
			[2, 'other'],
			[3, 'keeperOrReferee'],
			[4, 'other']
		]);
		expect(kits.groups[0].crops[0]).toMatchObject({ id: 'c0_00', imageUrl: expect.stringMatching(/^data:image\/svg\+xml,/) });
		job = await api.answerCheck(job, { question: 'kits', round: 1, split: 2 });
		expect(job.status).toBe('refitting');
		advance(MOCK_JOB_MS.refit);
		job = await reload(job);
		kits = (await api.jobQuestions(job)).questions.kits!;
		expect(kits).toMatchObject({ round: 2, splitAllowed: false });
		expect(kits.groups).toHaveLength(6);
		await expect(api.answerCheck(job, { question: 'kits', round: 2, split: 0 })).rejects.toSatisfy(refuses(400));
		job = await api.answerCheck(job, {
			question: 'kits',
			round: 2,
			tapped: { '0': ['c0_07'] },
			keeperOrReferee: [4],
			notKit: [5]
		});
		expect(job).toMatchObject({ status: 'queued', phase: 'run', checks: { pitch: 'answered', kits: 'answered' } });

		// The run, then the video.
		await expect(api.jobVideo(job)).rejects.toSatisfy(refuses(409));
		advance(MOCK_JOB_MS.queue + MOCK_JOB_MS.run / 2);
		job = await reload(job);
		expect(job).toMatchObject({ status: 'running', progress: { stage: 'render' } });
		advance(MOCK_JOB_MS.run);
		job = await reload(job);
		expect(job).toMatchObject({ status: 'done', progress: null });
		expect(job.finishedAt).not.toBeNull();
		const v = await api.jobVideo(job);
		expect(v.video.url).toMatch(/^data:video\/mp4;base64,AAAA/);
		expect(v.video.bytes).toBeGreaterThan(10_000);
		await expect(api.cancelJob(job)).rejects.toSatisfy(refuses(409));
	});

	it('cancels a job in flight, and the recording can be started again', async () => {
		const { api, advance } = setup();
		const job = await api.startJob(GAME, FRESH);
		advance(MOCK_JOB_MS.queue + 1000);
		await api.cancelJob(job);
		expect((await api.getJob(job.gameId, job.recordingId, job.jobId)).status).toBe('cancelled');
		expect((await api.startJob(GAME, FRESH)).status).toBe('queued');
	});

	it('refuses a recording that is still uploading, and an account without the cloud', async () => {
		const { api } = setup();
		await expect(api.startJob('g-7f3a9c21-4e6b-4b1d-9a20-5c8e1f0d2b11', 'rec-1h-7c2e')).rejects.toSatisfy(refuses(409));
		await api.adminSetCloudProcessing('mock-account-0001', false);
		expect((await api.me()).cloudProcessing).toBe(false);
		expect((await api.adminAccounts()).accounts.find((a) => a.accountId === 'mock-account-0001')!.cloudProcessing).toBe(false);
		await expect(api.startJob(GAME, FRESH)).rejects.toSatisfy(refuses(403));
	});
});

describe('the sharing wording', () => {
	it('is the approved share-v1 text, word for word', async () => {
		const { readFileSync } = await import('node:fs');
		const { SHARE_CONSENT_TEXT, SHARE_CONSENT_VERSION, consentBlocks } = await import('../src/lib/consent.ts');
		const approved = readFileSync(new URL(`../../shared/consent/${SHARE_CONSENT_VERSION}.md`, import.meta.url), 'utf8')
			.split('-->')[1]
			.trim();
		expect(SHARE_CONSENT_TEXT.trim()).toBe(approved);
		const blocks = consentBlocks();
		expect(blocks[0]).toMatchObject({ kind: 'heading' });
		expect(blocks.filter((b) => b.kind === 'bullet')).toHaveLength(8);
		expect(blocks.at(-1)).toMatchObject({ kind: 'link', url: 'https://opensportsball.com/privacy' });
		expect(blocks.some((b) => b.runs.some((r) => r.bold && r.text.includes('children')))).toBe(true);
	});
});

describe('job wording', () => {
	const job = (status: Job['status'], phase: Job['phase'] = 'prepare', where: Job['where'] = 'cloud') => ({
		status,
		phase,
		where,
		progress: null
	});

	it('says what a job is doing', () => {
		expect(jobHeadline(job('queued'))).toBe('Waiting for a machine');
		expect(jobHeadline(job('queued', 'run'))).toBe('Waiting for a machine to make the video');
		expect(jobHeadline(job('needs_answers'))).toBe('Waiting for your checks');
		expect(jobHeadline(job('running', 'run', 'local'))).toBe('Processing on your computer');
		expect(jobHeadline(job('done', 'run'))).toBe('Video ready');
	});

	it('knows which jobs are still going', () => {
		expect(jobIsActive(null)).toBe(false);
		expect(jobIsActive(job('needs_answers'))).toBe(true);
		for (const s of ['done', 'failed', 'cancelled'] as const) expect(jobIsActive(job(s))).toBe(false);
	});

	it('rounds the time left', () => {
		expect(formatEta(null)).toBe('');
		expect(formatEta(40)).toBe('about a minute left');
		expect(formatEta(600)).toBe('about 10 minutes left');
		expect(formatEta(3600 * 2.4)).toBe('about 2 hours left');
		expect(formatEta(5400)).toBe('about 2 hours left');
	});
});
