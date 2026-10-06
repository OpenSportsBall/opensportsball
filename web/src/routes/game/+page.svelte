<!-- SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import ProgressBar from '#lib/components/ProgressBar.svelte';
	import StatusBadge from '#lib/components/StatusBadge.svelte';
	import { formatBytes, formatDateTime, fraction, percent, roleLabel, shortId } from '#lib/format.ts';
	import { poll } from '#lib/poll.ts';
	import { session } from '#lib/session.svelte.ts';
	import type { Game, RecordingDevice } from '#lib/types.ts';

	const REFRESH_MS = 15_000;

	const gameId = $derived(page.url.searchParams.get('id'));
	let game = $state<Game | null>(null);
	let error = $state<unknown>(null);
	let updatedAt = $state<Date | null>(null);
	/** Linked phones' models, to name phones before the manifest arrives. */
	let knownModels = $state<Record<string, string>>({});

	const stillUploading = $derived(game?.recordings.some((r) => r.status !== 'ready') ?? false);

	async function load(): Promise<boolean> {
		if (!gameId) return false;
		try {
			const g = await session.api.getGame(gameId);
			g.recordings.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
			game = g;
			error = null;
			updatedAt = new Date();
		} catch (e) {
			error = e;
		}
		return game?.recordings.some((r) => r.status !== 'ready') ?? true;
	}

	async function loadModels() {
		try {
			const devices = await session.api.listDevices();
			knownModels = Object.fromEntries(devices.map((d) => [d.deviceId, d.model]));
		} catch {
			/* names are a nicety; the page works without them */
		}
	}

	onMount(() => {
		let stop = () => {};
		let destroyed = false;
		(async () => {
			if (!(await session.requireSignIn()) || destroyed || !gameId) return;
			void loadModels();
			if (await load()) stop = poll(load, REFRESH_MS);
		})();
		return () => {
			destroyed = true;
			stop();
		};
	});

	function phoneName(d: RecordingDevice): string {
		return d.model ?? knownModels[d.deviceId] ?? `Phone ${shortId(d.deviceId)}`;
	}

	function plural(n: number, word: string) {
		return `${n} ${word}${n === 1 ? '' : 's'}`;
	}
</script>

<svelte:head><title>Game · SportsBallVideo</title></svelte:head>

<p class="back"><a href={resolve('/games')}>← All games</a></p>

{#if !gameId}
	<ErrorBanner error="No game selected. Pick one from the Games page." />
{:else}
	{#if error}<ErrorBanner {error} retry={() => void load()} />{/if}

	{#if game === null && !error}
		<p class="muted">Loading game…</p>
	{:else if game}
		<div class="page-head">
			<div>
				<h1>{formatDateTime(game.createdAt)}</h1>
				<div class="muted small">
					{plural(game.recordings.length, 'recording')} · <span class="mono">{game.gameId}</span>
				</div>
			</div>
		</div>

		{#if stillUploading && updatedAt}
			<p class="muted small refresh" aria-live="polite">
				Still uploading. This page refreshes every 15 seconds (last checked {updatedAt.toLocaleTimeString()}).
			</p>
		{/if}

		{#if game.recordings.length === 0}
			<div class="card empty"><p>No recordings in this game yet.</p></div>
		{/if}

		<div class="recordings">
			{#each game.recordings as rec, i (rec.recordingId)}
				<section class="card recording">
					<div class="rec-head">
						<div>
							<h2>Recording {i + 1}</h2>
							<div class="muted small">Started {formatDateTime(rec.createdAt)}</div>
						</div>
						<StatusBadge status={rec.status} />
					</div>

					{#if !rec.hasManifest}
						<p class="muted small note">
							Waiting for the main phone to send the recording's manifest (the list of files to expect). Totals
							show up once it arrives.
						</p>
					{/if}

					{#if rec.devices.length === 0}
						<p class="muted small">No phone has uploaded anything for this recording yet.</p>
					{/if}

					<ul class="devices">
						{#each rec.devices as d (d.deviceId)}
							<li>
								<div class="dev-head">
									<div class="dev-name">
										<strong>{phoneName(d)}</strong>
										<span class="muted small">{roleLabel(d.role)}</span>
									</div>
									<span class="pct">{percent(d.uploadedSegments, d.expectedSegments)}</span>
								</div>
								<ProgressBar
									value={fraction(d.uploadedSegments, d.expectedSegments)}
									label="Upload progress for {phoneName(d)}"
								/>
								<div class="dev-stats muted small">
									{#if d.expectedSegments != null}
										<span>{d.uploadedSegments} of {plural(d.expectedSegments, 'segment')}</span>
										<span>{formatBytes(d.uploadedBytes)} of {formatBytes(d.expectedBytes)}</span>
									{:else}
										<span>{plural(d.uploadedSegments, 'segment')} uploaded so far</span>
										<span>{formatBytes(d.uploadedBytes)} so far</span>
									{/if}
								</div>
							</li>
						{/each}
					</ul>
				</section>
			{/each}
		</div>
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
	.page-head h1 {
		font-size: clamp(1.25rem, 5vw, 1.6rem);
	}
	.page-head .mono {
		word-break: break-all;
	}
	.refresh {
		margin-top: -0.5rem;
	}
	.recordings {
		display: grid;
		gap: 0.9rem;
	}
	.rec-head {
		display: flex;
		justify-content: space-between;
		align-items: flex-start;
		gap: 0.75rem;
		margin-bottom: 0.75rem;
	}
	.rec-head h2 {
		margin: 0;
	}
	.note {
		background: var(--warn-bg);
		color: var(--warn);
		border-radius: 8px;
		padding: 0.5rem 0.75rem;
	}
	.devices {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 1rem;
	}
	.dev-head {
		display: flex;
		justify-content: space-between;
		align-items: baseline;
		gap: 0.5rem;
		margin-bottom: 0.35rem;
	}
	.dev-name {
		display: flex;
		flex-wrap: wrap;
		column-gap: 0.5rem;
		align-items: baseline;
		min-width: 0;
	}
	.pct {
		font-weight: 600;
		font-variant-numeric: tabular-nums;
	}
	.dev-stats {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		gap: 0.25rem 1rem;
		margin-top: 0.3rem;
		font-variant-numeric: tabular-nums;
	}
</style>
