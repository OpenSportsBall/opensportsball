<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import StatusBadge from '#lib/components/StatusBadge.svelte';
	import { formatDateTime, recordedTime } from '#lib/format.ts';
	import { poll } from '#lib/poll.ts';
	import { session } from '#lib/session.svelte.ts';
	import { APP_STORE_URL } from '#lib/site.ts';
	import type { GameSummary } from '#lib/types.ts';

	const REFRESH_MS = 15_000;

	let games = $state<GameSummary[] | null>(null);
	let error = $state<unknown>(null);

	async function load(): Promise<boolean> {
		try {
			const list = await session.api.listGames();
			games = [...list].sort((a, b) => recordedTime(b).localeCompare(recordedTime(a)));
			error = null;
		} catch (e) {
			error = e;
		}
		return games?.some((g) => g.status !== 'ready') ?? false;
	}

	onMount(() => {
		let stop = () => {};
		let destroyed = false;
		(async () => {
			if (!(await session.requireSignIn()) || destroyed) return;
			if (await load()) stop = poll(load, REFRESH_MS);
		})();
		return () => {
			destroyed = true;
			stop();
		};
	});

	function plural(n: number, word: string) {
		return `${n} ${word}${n === 1 ? '' : 's'}`;
	}
</script>

<svelte:head><title>Games · OpenSportsBall</title></svelte:head>

<div class="page-head"><h1>Games</h1></div>

{#if error}<ErrorBanner {error} retry={() => void load()} />{/if}

{#if games === null && !error}
	<p class="muted">Loading games…</p>
{:else if games && games.length === 0}
	<div class="card empty">
		<h2>No games yet</h2>
		<ol>
			<li>Link your phones on the <a href={resolve('/devices')}>Devices</a> page.</li>
			<li>Record a game with the OpenSportsBall app (<a href={APP_STORE_URL} target="_blank" rel="noopener">iPhone</a>).</li>
			<li>The phones upload the footage when they are on Wi-Fi. The game shows up here.</li>
		</ol>
		<div><a class="btn btn-primary" href="{resolve('/devices')}?link=1">Link a phone</a></div>
	</div>
{:else if games}
	<ul class="games">
		{#each games as g (g.gameId)}
			<li>
				<a class="card game" href="{resolve('/game')}?id={encodeURIComponent(g.gameId)}">
					<div class="main">
						<div class="date">{formatDateTime(recordedTime(g))}</div>
						<div class="muted small">{plural(g.recordingCount, 'recording')}</div>
					</div>
					<StatusBadge status={g.status} />
				</a>
			</li>
		{/each}
	</ul>
{/if}

<style>
	.games {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 0.6rem;
	}
	.game {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
		color: inherit;
		text-decoration: none;
	}
	.game:hover {
		border-color: var(--accent);
	}
	.main {
		min-width: 0;
	}
	.date {
		font-weight: 600;
	}
</style>
