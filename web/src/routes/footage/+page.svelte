<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { ApiError } from '#lib/api.ts';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import { footageByPhone, parseFootageFragment } from '#lib/footageLink.ts';
	import { formatBytes, formatDateTime, roleLabel, shortId } from '#lib/format.ts';
	import { session } from '#lib/session.svelte.ts';
	import type { FootagePage } from '#lib/types.ts';

	// Opened by whoever was sent the link, usually with no account: no
	// sign-in here. The link holds a token; the API says what it is for.
	type State =
		| { kind: 'loading' }
		| { kind: 'broken' }
		| { kind: 'missing' }
		| { kind: 'expired' }
		| { kind: 'error'; error: unknown }
		| { kind: 'ready'; page: FootagePage };
	let view = $state<State>({ kind: 'loading' });

	const phones = $derived(view.kind === 'ready' ? footageByPhone(view.page) : []);
	const totalBytes = $derived(phones.reduce((sum, p) => sum + p.bytes, 0));
	const fileCount = $derived(phones.reduce((n, p) => n + p.files.length, 0));

	/** Fresh file links a little before these stop, or the page's end. */
	const EARLY_MS = 5 * 60_000;
	let timer: ReturnType<typeof setTimeout> | undefined;

	async function load(quiet = false) {
		clearTimeout(timer);
		const token = parseFootageFragment(window.location.hash);
		if (!token) {
			view = { kind: 'broken' };
			return;
		}
		if (!quiet) view = { kind: 'loading' };
		try {
			await session.init();
			const page = await session.api.lookupFootageLink(token);
			view = { kind: 'ready', page };
			const end = Date.parse(page.expiresAt);
			const links = Date.parse(page.linksExpireAt);
			// setTimeout can't wait longer than about 24 days; these are at most 12 hours.
			const wait = (links < end ? links - EARLY_MS : end) - Date.now();
			timer = setTimeout(() => void load(true), Math.max(wait, 30_000));
		} catch (e) {
			if (e instanceof ApiError && e.status === 404) view = { kind: 'missing' };
			else if (e instanceof ApiError && e.status === 410) view = { kind: 'expired' };
			// A refresh that could not get through leaves the links there, which still work for a while.
			else if (!quiet) view = { kind: 'error', error: e };
		}
	}

	onMount(() => {
		void load();
		// Another link opened in this same tab changes only the fragment.
		const again = () => void load();
		window.addEventListener('hashchange', again);
		return () => {
			clearTimeout(timer);
			window.removeEventListener('hashchange', again);
		};
	});

	function plural(n: number, word: string) {
		return `${n} ${word}${n === 1 ? '' : 's'}`;
	}
</script>

<svelte:head>
	<title>Raw video · OpenSportsBall</title>
	<meta name="robots" content="noindex" />
</svelte:head>

{#if view.kind === 'ready'}
	{@const page = view.page}
	<div class="page-head">
		<div>
			<h1>Raw video{page.recordedAt ? ` from ${formatDateTime(page.recordedAt)}` : ''}</h1>
			<div class="muted small">
				{plural(fileCount, 'file')}, {formatBytes(totalBytes)} in all, as the phones recorded them
			</div>
		</div>
	</div>

	<p class="note small">
		This page works until <strong>{formatDateTime(page.expiresAt)}</strong>. Anyone with its address can download these
		files until then, so pass it on only to people who should have them.
	</p>

	{#if page.status !== 'ready'}
		<p class="muted small">
			The phones are still uploading this recording: these are the files that have arrived so far. Reload the page to
			see more.
		</p>
	{/if}

	{#if fileCount === 0}
		<div class="card empty"><p>No video has been uploaded for this recording yet.</p></div>
	{/if}

	<div class="phones">
		{#each phones as p (p.deviceId)}
			<section class="card">
				<div class="phone-head">
					<h2>{p.model ?? `Phone ${shortId(p.deviceId)}`}</h2>
					<span class="muted small">
						{p.role ? `${roleLabel(p.role)} · ` : ''}{plural(p.files.length, 'file')} · {formatBytes(p.bytes)}
					</span>
				</div>
				<ol class="files">
					{#each p.files as f, i (f.fileName)}
						<li>
							<div class="file">
								<span>Part {i + 1}</span>
								<span class="muted small mono name">{f.fileName}</span>
							</div>
							<a class="btn btn-small" href={f.url} download={f.fileName}>Download ({formatBytes(f.bytes)})</a>
						</li>
					{/each}
				</ol>
			</section>
		{/each}
	</div>

	{#if fileCount > 0}
		<p class="muted small after">
			Each phone's parts follow one another with no gap: play or join them in order.
			{#if page.manifestUrl}
				The <a href={page.manifestUrl} download="manifest.json">recording's manifest</a> lists every file with its
				start time and SHA-256 checksum.
			{/if}
		</p>
	{/if}
{:else}
	<section class="card stack message">
		{#if view.kind === 'loading'}
			<p class="muted">Checking the link…</p>
		{:else if view.kind === 'broken'}
			<h1>This link is not complete</h1>
			<p>Copy the whole link again from the message it came in.</p>
		{:else if view.kind === 'missing'}
			<h1>This link does not work</h1>
			<p>It was stopped, or the recording was deleted. Ask whoever sent it for a new one.</p>
		{:else if view.kind === 'expired'}
			<h1>This link has expired</h1>
			<p>Ask whoever sent it for a new one.</p>
		{:else if view.kind === 'error'}
			<h1>Could not check this link</h1>
			<ErrorBanner error={view.error} retry={() => void load()} />
		{/if}
	</section>
{/if}

<style>
	.page-head h1,
	.message h1 {
		font-size: clamp(1.25rem, 5vw, 1.6rem);
	}
	.message {
		max-width: 520px;
		margin: 1rem auto;
		text-align: center;
	}
	.note {
		background: var(--warn-bg);
		color: var(--warn);
		border-radius: 8px;
		padding: 0.5rem 0.75rem;
	}
	.phones {
		display: grid;
		gap: 0.9rem;
	}
	.phone-head {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		align-items: baseline;
		gap: 0.25rem 0.75rem;
		margin-bottom: 0.6rem;
	}
	.phone-head h2 {
		margin: 0;
	}
	.files {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.files li {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 0.75rem;
		padding: 0.45rem 0;
	}
	.files li + li {
		border-top: 1px solid var(--border);
	}
	.file {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		column-gap: 0.6rem;
		min-width: 0;
		font-variant-numeric: tabular-nums;
	}
	.name {
		word-break: break-all;
	}
	.files a {
		text-decoration: none;
		white-space: nowrap;
		flex-shrink: 0;
	}
	.after {
		margin-top: 0.9rem;
	}
</style>
