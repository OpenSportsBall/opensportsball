<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/**
	 * One recording's download pages: make a link to a page listing every raw
	 * video file, for someone with no account, that works for a day, three
	 * days or a week; see the ones still working and stop them.
	 */
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import { FOOTAGE_LINK_HOURS, footagePageUrl } from '#lib/footageLink.ts';
	import { formatDateTime } from '#lib/format.ts';
	import { session } from '#lib/session.svelte.ts';
	import type { FootageLink } from '#lib/types.ts';

	let { gameId, recordingId }: { gameId: string; recordingId: string } = $props();

	let open = $state(false);
	let links = $state<FootageLink[] | null>(null);
	let hours = $state<number>(FOOTAGE_LINK_HOURS[0].hours);
	let busy = $state(false);
	let error = $state<unknown>(null);
	/** The link just made. Its address can't be shown again: only its hash is kept. */
	let made = $state<{ linkId: string; url: string; expiresAt: string } | null>(null);
	let copied = $state(false);
	let stopping = $state<string | null>(null);

	async function load() {
		error = null;
		try {
			links = await session.api.listFootageLinks(gameId, recordingId);
		} catch (e) {
			error = e;
		}
	}

	function show() {
		open = true;
		void load();
	}

	function close() {
		open = false;
		made = null;
		error = null;
	}

	async function create() {
		busy = true;
		error = null;
		copied = false;
		try {
			const l = await session.api.createFootageLink(gameId, recordingId, hours);
			made = { linkId: l.linkId, url: footagePageUrl(window.location.origin, l.token), expiresAt: l.expiresAt };
			links = [...(links ?? []), { linkId: l.linkId, createdAt: l.createdAt, expiresAt: l.expiresAt }];
		} catch (e) {
			error = e;
		} finally {
			busy = false;
		}
	}

	async function copy() {
		if (!made) return;
		try {
			await navigator.clipboard.writeText(made.url);
			copied = true;
		} catch (e) {
			error = e;
		}
	}

	async function stop(linkId: string) {
		stopping = linkId;
		error = null;
		try {
			await session.api.revokeFootageLink(gameId, recordingId, linkId);
			links = (links ?? []).filter((l) => l.linkId !== linkId);
			if (made?.linkId === linkId) made = null;
		} catch (e) {
			error = e;
		} finally {
			stopping = null;
		}
	}
</script>

<div class="share">
	{#if !open}
		<button class="btn btn-small" onclick={show}>Share the raw video…</button>
	{:else}
		<div class="head">
			<strong>Share the raw video</strong>
			<button class="btn btn-small" onclick={close}>Close</button>
		</div>
		<p class="muted small">
			Makes a page listing every video file the phones uploaded for this recording, each with a download link. Anyone
			you send the page to can download them, without an account, until it stops working.
		</p>
		{#if error}<ErrorBanner {error} />{/if}

		{#if made}
			<input
				class="link mono"
				readonly
				value={made.url}
				aria-label="Download page link"
				onfocus={(e) => e.currentTarget.select()}
			/>
			<div class="row">
				<button class="btn btn-primary btn-small" onclick={copy}>{copied ? 'Copied' : 'Copy link'}</button>
				<a class="btn btn-small" href={made.url} target="_blank" rel="noopener">Open the page</a>
			</div>
			<p class="small">
				Works until {formatDateTime(made.expiresAt)}. Copy it now: this address is not shown again.
			</p>
		{:else}
			<div class="row">
				<label class="small" for="hours-{recordingId}">Works for</label>
				<select id="hours-{recordingId}" bind:value={hours} disabled={busy}>
					{#each FOOTAGE_LINK_HOURS as o (o.hours)}
						<option value={o.hours}>{o.label}</option>
					{/each}
				</select>
				<button class="btn btn-primary btn-small" onclick={create} disabled={busy}>
					{busy ? 'Making the page…' : 'Make a download page'}
				</button>
			</div>
		{/if}

		{#if links === null && !error}
			<p class="muted small">Loading…</p>
		{:else if links && links.length > 0}
			<ul class="links">
				{#each links as l (l.linkId)}
					<li>
						<span class="small">
							Page made {formatDateTime(l.createdAt)}, works until {formatDateTime(l.expiresAt)}
						</span>
						<button class="btn btn-small btn-danger" onclick={() => stop(l.linkId)} disabled={stopping !== null}>
							{stopping === l.linkId ? 'Stopping…' : 'Stop sharing'}
						</button>
					</li>
				{/each}
			</ul>
			<p class="muted small">
				Stopping a page stops it opening. Someone who has it open can still download for up to 12 hours after they
				opened it.
			</p>
		{/if}
	{/if}
</div>

<style>
	.share {
		margin-top: 0.9rem;
		padding-top: 0.75rem;
		border-top: 1px solid var(--border);
	}
	.head {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 0.75rem;
	}
	.share p {
		margin: 0.5rem 0;
	}
	.row {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.5rem;
		margin: 0.5rem 0;
	}
	.row a {
		text-decoration: none;
	}
	select {
		font: inherit;
		padding: 0.3rem 0.5rem;
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-sm);
		background: var(--surface);
		color: var(--text);
	}
	.link {
		width: 100%;
		box-sizing: border-box;
		font-size: 0.8rem;
		padding: 0.5rem 0.6rem;
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-sm);
		background: var(--surface-2);
		color: var(--text);
		text-overflow: ellipsis;
	}
	.links {
		list-style: none;
		margin: 0.75rem 0 0;
		padding: 0;
		display: grid;
		gap: 0.4rem;
	}
	.links li {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		align-items: center;
		gap: 0.5rem;
	}
</style>
