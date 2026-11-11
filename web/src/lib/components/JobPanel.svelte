<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/**
	 * Processing for one ready recording: start it in the cloud, follow it,
	 * go to the checks, then watch and download the video.
	 */
	import { resolve } from '$app/paths';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import ProgressBar from '#lib/components/ProgressBar.svelte';
	import { formatBytes, formatDateTime, formatEta, jobHeadline, jobIsActive, stageLabel } from '#lib/format.ts';
	import { session } from '#lib/session.svelte.ts';
	import type { Job, JobVideo, Recording } from '#lib/types.ts';

	let { gameId, rec, onchange }: { gameId: string; rec: Recording; onchange: () => void } = $props();

	const job = $derived(rec.job);
	const active = $derived(jobIsActive(job));
	let busy = $state(false);
	let error = $state<unknown>(null);
	let confirmingCancel = $state(false);
	let video = $state<JobVideo | null>(null);
	/** The job the loaded video link belongs to. */
	let videoJobId = $state<string | null>(null);

	const checkHref = (j: Job) =>
		`${resolve('/check')}?game=${encodeURIComponent(j.gameId)}&recording=${encodeURIComponent(j.recordingId)}&job=${encodeURIComponent(j.jobId)}`;

	async function act(fn: () => Promise<unknown>) {
		busy = true;
		error = null;
		try {
			await fn();
			onchange();
		} catch (e) {
			error = e;
		} finally {
			busy = false;
		}
	}

	const start = () => act(() => session.api.startJob(gameId, rec.recordingId));
	const cancel = (j: Job) =>
		act(async () => {
			await session.api.cancelJob(j);
			confirmingCancel = false;
		});
	const watch = (j: Job) =>
		act(async () => {
			video = await session.api.jobVideo(j);
			videoJobId = j.jobId;
		});

	const shownVideo = $derived(job && video && videoJobId === job.jobId ? video.video : null);
</script>

{#if rec.status === 'ready'}
	<div class="job" aria-live="polite">
		{#if error}<ErrorBanner {error} />{/if}

		{#if job && active}
			<div class="head">
				<strong>{jobHeadline(job)}</strong>
				{#if job.progress && (job.status === 'preparing' || job.status === 'running')}
					<span class="pct">{Math.floor(job.progress.fraction * 100)}%</span>
				{/if}
			</div>

			{#if job.status === 'needs_answers'}
				{#if job.where === 'cloud'}
					<p class="small">
						Two quick checks before the video is made: that we found the pitch, and that we sorted the kits.
					</p>
					<a class="btn btn-primary" href={checkHref(job)}>Do the checks</a>
				{:else}
					<p class="muted small">Answer the checks in the app on your computer.</p>
				{/if}
			{:else}
				<ProgressBar
					value={job.progress && (job.status === 'preparing' || job.status === 'running') ? job.progress.fraction : null}
					label={jobHeadline(job)}
				/>
				<p class="muted small detail">
					{#if job.status === 'queued'}
						A machine is starting. This usually takes a few minutes.
					{:else if job.progress}
						{[stageLabel(job.progress.stage), formatEta(job.progress.etaSeconds)].filter(Boolean).join(' · ')}
					{:else if job.status === 'running'}
						This takes a few hours. We'll email you when the video is ready.
					{:else}
						This takes a few minutes.
					{/if}
				</p>
			{/if}

			{#if job.where === 'cloud'}
				{#if confirmingCancel}
					<div class="confirm-buttons">
						<span class="small">Stop processing this recording?</span>
						<button class="btn btn-small" onclick={() => (confirmingCancel = false)} disabled={busy}>Keep going</button>
						<button class="btn btn-small btn-danger-solid" onclick={() => cancel(job)} disabled={busy}>
							{busy ? 'Stopping…' : 'Stop'}
						</button>
					</div>
				{:else}
					<button class="btn btn-small cancel" onclick={() => (confirmingCancel = true)}>Cancel</button>
				{/if}
			{/if}
		{:else}
			{#if job?.status === 'done'}
				<div class="head">
					<strong>Video ready</strong>
					<span class="muted small">{formatDateTime(job.finishedAt)}</span>
				</div>
				{#if shownVideo}
					<!-- svelte-ignore a11y_media_has_caption -->
					<video controls preload="metadata" src={shownVideo.url}></video>
					<div class="actions">
						<a class="btn" href={shownVideo.url} download={shownVideo.fileName}>
							{shownVideo.bytes ? `Download (${formatBytes(shownVideo.bytes)})` : 'Download'}
						</a>
					</div>
				{:else}
					<button class="btn btn-primary" onclick={() => watch(job)} disabled={busy}>
						{busy ? 'Getting the video…' : 'Watch the video'}
					</button>
				{/if}
				{#if job.stale}
					<p class="small note">
						A second phone's footage arrived after this video was made, so it shows one phone's view only.
					</p>
				{/if}
			{:else if job?.status === 'failed'}
				<p class="small failed"><strong>Processing failed.</strong> {job.error?.message ?? ''}</p>
			{:else if job?.status === 'cancelled'}
				<p class="muted small">
					{job.error?.code === 'superseded' ? job.error.message : 'Processing was cancelled.'}
				</p>
			{/if}

			{#if session.cloudProcessing}
				{#if !job}
					<button class="btn btn-primary" onclick={start} disabled={busy}>
						{busy ? 'Starting…' : 'Process in the cloud'}
					</button>
					<p class="muted small detail">
						Makes the followed game video on our machines. You answer two quick checks first; the video takes a few
						hours.
					</p>
				{:else if job.status !== 'done' || job.stale}
					<button class="btn" onclick={start} disabled={busy}>
						{busy ? 'Starting…' : job.stale ? 'Process again with both phones' : 'Try again'}
					</button>
				{/if}
			{:else if !job}
				<p class="muted small">Cloud processing isn't switched on for this account.</p>
			{/if}
		{/if}
	</div>
{/if}

<style>
	.job {
		margin-top: 1rem;
		padding-top: 0.9rem;
		border-top: 1px solid var(--border);
		display: grid;
		gap: 0.5rem;
		justify-items: start;
	}
	.job > :global(*) {
		margin: 0;
	}
	.job > :global(.track),
	.head,
	video {
		width: 100%;
	}
	.head {
		display: flex;
		justify-content: space-between;
		align-items: baseline;
		gap: 0.5rem;
	}
	.pct {
		font-weight: 600;
		font-variant-numeric: tabular-nums;
	}
	video {
		border-radius: var(--radius-sm);
		background: #000;
		aspect-ratio: 16 / 9;
	}
	.actions,
	.confirm-buttons {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.5rem;
	}
	.note,
	.failed {
		border-radius: 8px;
		padding: 0.5rem 0.75rem;
	}
	.note {
		background: var(--warn-bg);
		color: var(--warn);
	}
	.failed {
		background: var(--danger-bg);
		color: var(--danger);
	}
</style>
