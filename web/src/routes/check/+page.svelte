<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/**
	 * The two checks a cloud job waits for between getting a game ready and
	 * making its video: the pitch, then the kit groups. The engine wrote the
	 * questions; this page only draws them and sends back the answers.
	 */
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import KitsCheck from '#lib/components/KitsCheck.svelte';
	import PitchCheck from '#lib/components/PitchCheck.svelte';
	import ProgressBar from '#lib/components/ProgressBar.svelte';
	import { session } from '#lib/session.svelte.ts';
	import type { CheckName, Job, JobQuestions, KitsAnswer, PitchAnswer } from '#lib/types.ts';

	const WAIT_MS = 2_000;

	const gameId = $derived(page.url.searchParams.get('game'));
	const recordingId = $derived(page.url.searchParams.get('recording'));
	const jobId = $derived(page.url.searchParams.get('job'));
	const gameHref = $derived(`${resolve('/game')}?id=${encodeURIComponent(gameId ?? '')}`);

	let job = $state<Job | null>(null);
	let questions = $state<JobQuestions['questions'] | null>(null);
	let error = $state<unknown>(null);
	let busy = $state(false);
	/** The check being redone, to say what we are waiting for. */
	let redoing = $state<CheckName | null>(null);
	/** Who was tapped before a group was split, kept for when the groups come back. */
	let marked = $state<KitsAnswer['wrong']>([]);
	let timer: ReturnType<typeof setTimeout> | undefined;
	let destroyed = false;

	/** The check to show: the pitch first, then the kits. */
	const current = $derived<CheckName | null>(
		job?.status !== 'needs_answers' ? null : job.checks.pitch === 'open' ? 'pitch' : job.checks.kits === 'open' ? 'kits' : null
	);
	const waiting = $derived(job?.phase === 'prepare' && ['queued', 'preparing', 'refitting'].includes(job.status));

	async function load() {
		if (!gameId || !recordingId || !jobId) return;
		clearTimeout(timer);
		try {
			const j = await session.api.getJob(gameId, recordingId, jobId);
			if (j.status === 'needs_answers' && j.where === 'cloud') {
				questions = (await session.api.jobQuestions(j)).questions;
				redoing = null;
			}
			job = j;
			error = null;
		} catch (e) {
			error = e;
		}
		if (!destroyed && (waiting || (error && !job))) timer = setTimeout(load, WAIT_MS);
	}

	async function answer(a: PitchAnswer | KitsAnswer) {
		if (!job) return;
		busy = true;
		error = null;
		try {
			const next = await session.api.answerCheck(job, a);
			if (next.status === 'refitting') redoing = a.check;
			if (a.check === 'kits') marked = a.wrong;
			job = next;
			await load();
			window.scrollTo({ top: 0 });
		} catch (e) {
			error = e;
			// The questions may have changed under us (a refit finished elsewhere).
			await load().catch(() => {});
		} finally {
			busy = false;
		}
	}

	onMount(() => {
		(async () => {
			if (!(await session.requireSignIn()) || destroyed) return;
			await load();
		})();
		return () => {
			destroyed = true;
			clearTimeout(timer);
		};
	});

	const step = (name: CheckName) => (job?.checks[name] === 'answered' ? 'done' : current === name ? 'now' : 'todo');
</script>

<svelte:head><title>Check the game · OpenSportsBall</title></svelte:head>

<p class="back"><a href={gameHref}>← Back to the game</a></p>

{#if !gameId || !recordingId || !jobId}
	<ErrorBanner error="No game selected. Pick one from the Games page." />
{:else}
	<h1>Check the game</h1>
	{#if error}<ErrorBanner {error} retry={() => void load()} />{/if}

	{#if job === null && !error}
		<p class="muted">Loading…</p>
	{:else if job}
		{#if job.where === 'cloud' && job.phase === 'prepare' && !['failed', 'cancelled'].includes(job.status)}
			<ol class="steps" aria-label="Checks">
				<li class={step('pitch')}><span class="n">{job.checks.pitch === 'answered' ? '✓' : '1'}</span> The pitch</li>
				<li class={step('kits')}><span class="n">{job.checks.kits === 'answered' ? '✓' : '2'}</span> The kits</li>
			</ol>
		{/if}

		{#if job.where !== 'cloud'}
			<div class="card"><p>This game is being processed on your own computer. Answer its checks in the app there.</p></div>
		{:else if current && questions}
			<section class="card">
				{#if current === 'pitch'}
					<h2>Did we find the pitch?</h2>
					{#key questions.pitch.round}
						<PitchCheck q={questions.pitch} {busy} onanswer={answer} />
					{/key}
				{:else}
					<h2>Did we sort the kits?</h2>
					{#key `${questions.kits.round}/${questions.kits.groups.length}`}
						<KitsCheck q={questions.kits} {busy} {marked} onanswer={answer} />
					{/key}
				{/if}
			</section>
		{:else if waiting}
			<section class="card" aria-live="polite">
				<h2>
					{#if job.status !== 'refitting'}
						Getting the game ready
					{:else if redoing === 'kits'}
						Splitting that group
					{:else}
						Redrawing the pitch from your points
					{/if}
				</h2>
				<ProgressBar value={job.status === 'preparing' && job.progress ? job.progress.fraction : null} label="Working" />
				<p class="muted small">
					{job.status === 'refitting'
						? "This takes a minute or two. We'll show you the result here."
						: 'The checks will appear here in a few minutes.'}
				</p>
			</section>
		{:else if job.status === 'failed' || job.status === 'cancelled'}
			<div class="card">
				<p>
					{job.status === 'failed' ? 'Processing failed.' : 'Processing was cancelled.'}
					{job.error?.message ?? ''}
				</p>
				<a class="btn" href={gameHref}>Back to the game</a>
			</div>
		{:else}
			<div class="card done" aria-live="polite">
				<h2>Thanks, that's both checks</h2>
				<p>
					{job.status === 'done'
						? 'The video is ready.'
						: "The video is being made now. It takes a few hours, and we'll email you when it's ready."}
				</p>
				<a class="btn btn-primary" href={gameHref}>Back to the game</a>
			</div>
		{/if}
	{/if}
{/if}

<style>
	.back {
		margin-bottom: 0.5rem;
	}
	.back a {
		text-decoration: none;
		font-weight: 600;
	}
	h1 {
		font-size: clamp(1.25rem, 5vw, 1.6rem);
	}
	h2 {
		margin: 0 0 0.5rem;
	}
	.steps {
		list-style: none;
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem 1.5rem;
		padding: 0;
		margin: 0 0 0.9rem;
		font-weight: 600;
		color: var(--text-muted);
	}
	.steps li {
		display: flex;
		align-items: center;
		gap: 0.45rem;
	}
	.n {
		display: inline-grid;
		place-items: center;
		width: 1.6rem;
		height: 1.6rem;
		border-radius: 999px;
		background: var(--surface-2);
		border: 1px solid var(--border);
		font-size: 0.85rem;
	}
	.steps .now {
		color: var(--text);
	}
	.steps .now .n {
		background: var(--accent);
		border-color: var(--accent);
		color: var(--accent-text);
	}
	.steps .done .n {
		background: var(--ok-bg);
		border-color: var(--ok);
		color: var(--ok);
	}
	.card :global(p:first-of-type) {
		margin-top: 0;
	}
</style>
