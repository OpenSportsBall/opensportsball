<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import StatusBadge from '#lib/components/StatusBadge.svelte';
	import { formatBytes, formatDateTime, shortId } from '#lib/format.ts';
	import { session } from '#lib/session.svelte.ts';
	import type { AdminAccountGames, AdminGame, AdminRecording } from '#lib/types.ts';

	/** The admin page's list of one account's games and recordings, each
	 *  with a two-step Delete. [onDeleted] lets the page refresh its totals. */
	let { accountId, onDeleted }: { accountId: string; onDeleted?: () => void } = $props();

	let data = $state<AdminAccountGames | null>(null);
	let error = $state<unknown>(null);
	/** Which game or recording is asking "are you sure?": its key below. */
	let confirming = $state<string | null>(null);
	let deleting = $state<string | null>(null);
	let deleteError = $state<unknown>(null);

	const gameKey = (g: AdminGame) => `g:${g.gameId}`;
	const recKey = (g: AdminGame, r: AdminRecording) => `r:${g.gameId}:${r.recordingId}`;

	async function load() {
		try {
			data = await session.api.adminAccountGames(accountId);
			error = null;
		} catch (e) {
			error = e;
		}
	}

	onMount(load);

	async function remove(key: string, run: () => Promise<void>) {
		deleting = key;
		deleteError = null;
		try {
			await run();
			confirming = null;
			await load();
			onDeleted?.();
		} catch (e) {
			deleteError = e;
		} finally {
			deleting = null;
		}
	}

	const deleteGame = (g: AdminGame) =>
		remove(gameKey(g), () => session.api.adminDeleteGame(accountId, g.gameId));
	const deleteRecording = (g: AdminGame, r: AdminRecording) =>
		remove(recKey(g, r), () => session.api.adminDeleteRecording(accountId, g.gameId, r.recordingId));

	const when = (x: { recordedAt: string | null; createdAt: string | null }) => x.recordedAt ?? x.createdAt;
	const owner = $derived(data?.email ?? 'this account');
	const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;
</script>

<div class="videos">
	{#if error}<ErrorBanner {error} retry={() => void load()} />{/if}
	{#if deleteError}<ErrorBanner error={deleteError} />{/if}

	{#if !data && !error}
		<p class="muted small">Loading games…</p>
	{:else if data && data.games.length === 0}
		<p class="muted small">No games or footage.</p>
	{:else if data}
		<ul class="games">
			{#each data.games as g (g.gameId)}
				<li class="game">
					<div class="row head">
						<div class="what">
							<strong>{when(g) ? formatDateTime(when(g)) : 'Date unknown'}</strong>
							<span class="muted small">
								{plural(g.recordings.length, 'recording')} · {formatBytes(g.storageBytes)} ·
								<span class="mono" title={g.gameId}>{shortId(g.gameId)}</span>
							</span>
							{#if !g.inTable}<span class="flag">Footage with no game record</span>{/if}
						</div>
						{#if confirming !== gameKey(g)}
							<button
								class="btn btn-small btn-danger"
								onclick={() => (confirming = gameKey(g))}
								disabled={deleting !== null}>Delete game</button
							>
						{/if}
					</div>
					{#if confirming === gameKey(g)}
						<div class="confirm">
							<p class="small">
								Delete this game from {owner}: {plural(g.recordings.length, 'recording')} and {formatBytes(g.storageBytes)}
								of footage? This is permanent. Their phones are told it was deleted.
							</p>
							<div class="buttons">
								<button class="btn btn-small" onclick={() => (confirming = null)} disabled={deleting !== null}>Cancel</button>
								<button class="btn btn-small btn-danger-solid" onclick={() => deleteGame(g)} disabled={deleting !== null}>
									{deleting === gameKey(g) ? 'Deleting…' : 'Delete game for good'}
								</button>
							</div>
						</div>
					{/if}

					<ul class="recordings">
						{#each g.recordings as r, i (r.recordingId)}
							<li>
								<div class="row">
									<div class="what">
										<span>Recording {i + 1}</span>
										<span class="muted small">
											{when(r) ? formatDateTime(when(r)) : 'date unknown'} · {formatBytes(r.storageBytes)} in
											{plural(r.objectCount, 'file')}
										</span>
										{#if r.status}<StatusBadge status={r.status} />{:else}<span class="flag">No record</span>{/if}
									</div>
									{#if confirming !== recKey(g, r)}
										<button
											class="btn btn-small btn-danger"
											onclick={() => (confirming = recKey(g, r))}
											disabled={deleting !== null}>Delete</button
										>
									{/if}
								</div>
								{#if confirming === recKey(g, r)}
									<div class="confirm">
										<p class="small">
											Delete Recording {i + 1} from {owner}: {formatBytes(r.storageBytes)} of footage? This is permanent.
										</p>
										<div class="buttons">
											<button class="btn btn-small" onclick={() => (confirming = null)} disabled={deleting !== null}
												>Cancel</button
											>
											<button
												class="btn btn-small btn-danger-solid"
												onclick={() => deleteRecording(g, r)}
												disabled={deleting !== null}
											>
												{deleting === recKey(g, r) ? 'Deleting…' : 'Delete for good'}
											</button>
										</div>
									</div>
								{/if}
							</li>
						{/each}
					</ul>
				</li>
			{/each}
		</ul>
	{/if}
</div>

<style>
	.videos {
		display: grid;
		gap: 0.5rem;
		width: 100%;
	}
	.games,
	.recordings {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.games {
		display: grid;
		gap: 0.5rem;
	}
	.game {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		padding: 0.5rem 0.7rem;
	}
	.recordings {
		margin-top: 0.35rem;
		border-top: 1px solid var(--border);
	}
	.recordings li {
		padding: 0.35rem 0 0.35rem 0.9rem;
	}
	.recordings li + li {
		border-top: 1px dashed var(--border);
	}
	.row {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 0.5rem;
	}
	.what {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		gap: 0.25rem 0.6rem;
		min-width: 0;
	}
	.flag {
		font-size: 0.78rem;
		font-weight: 700;
		color: var(--warn);
		background: var(--warn-bg);
		border-radius: 999px;
		padding: 0.05rem 0.5rem;
	}
	.confirm {
		margin-top: 0.4rem;
		padding: 0.5rem 0.7rem;
		border: 1px solid var(--danger-border);
		background: var(--danger-bg);
		border-radius: var(--radius-sm);
	}
	.confirm p {
		margin: 0 0 0.4rem;
	}
	.buttons {
		display: flex;
		gap: 0.5rem;
		justify-content: flex-end;
		flex-wrap: wrap;
	}
</style>
