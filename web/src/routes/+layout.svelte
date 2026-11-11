<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import '../app.css';
	import { onMount, type Snippet } from 'svelte';
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import { session } from '#lib/session.svelte.ts';
	import { APP_STORE_URL, MAC_DOWNLOAD_URL, REPO_URL } from '#lib/site.ts';

	let { children }: { children: Snippet } = $props();

	onMount(() => {
		void session.init();
	});

	const path = $derived(page.url.pathname);
	// Linked from the app stores: shown even when the site config can't load.
	const isInfoPage = $derived(path === '/privacy' || path === '/support');
</script>

<header class="site-header">
	<div class="bar">
		<a class="brand" href={resolve('/')}>
			<svg viewBox="0 0 64 64" width="30" height="30" aria-hidden="true">
				<path fill="var(--accent)" d="M30.5 4.04A28 28 0 0 0 30.5 59.96Z" />
				<path fill="var(--accent)" d="M33.5 4.04A28 28 0 0 1 33.5 59.96Z" />
				<path fill="var(--sun)" stroke="var(--sun)" stroke-width="4" stroke-linejoin="round" d="M25.5 21.5L43.5 32L25.5 42.5Z" />
			</svg>
			<span class="wordmark"><span class="open">Open</span>SportsBall</span>
		</a>
		{#if session.status === 'ready' && session.signedIn}
			<div class="account">
				{#if session.email}<span class="email" title={session.email}>{session.email}</span>{/if}
				<button class="btn btn-small" onclick={() => session.signOut()}>Sign out</button>
			</div>
		{/if}
	</div>
	{#if session.status === 'ready' && session.signedIn}
		<nav aria-label="Main">
			<a href={resolve('/games')} aria-current={path === '/games' || path === '/game' ? 'page' : undefined}>Games</a>
			<a href={resolve('/devices')} aria-current={path === '/devices' ? 'page' : undefined}>Devices</a>
			<a href={resolve('/account')} aria-current={path === '/account' ? 'page' : undefined}>Account</a>
			{#if session.admin}
				<a href={resolve('/admin')} aria-current={path === '/admin' ? 'page' : undefined}>Admin</a>
			{/if}
		</nav>
	{/if}
</header>

{#if session.mock && session.status === 'ready'}
	<div class="mock-note">Mock mode: sample data, no AWS. Nothing here is real.</div>
{/if}

<main class="container">
	{#if isInfoPage}
		{@render children()}
	{:else if session.status === 'loading'}
		<p class="muted">Loading…</p>
	{:else if session.status === 'error'}
		<div class="card stack">
			<h1>The site isn't set up correctly</h1>
			<p>{session.error}</p>
			<p class="muted small">
				The site reads its settings from <code>/config.json</code>. See <code>web/README.md</code>.
			</p>
		</div>
	{:else}
		{@render children()}
	{/if}
</main>

<footer class="site-footer">
	<a href={APP_STORE_URL} target="_blank" rel="noopener">iPhone app</a>
	<a href={MAC_DOWNLOAD_URL}>Mac app</a>
	<a href={resolve('/privacy')}>Privacy</a>
	<a href={resolve('/support')}>Support</a>
	<a href={REPO_URL}>Source code</a>
</footer>

<style>
	.site-header {
		background: var(--surface);
		border-bottom: 1px solid var(--border);
	}
	.bar {
		max-width: 880px;
		margin: 0 auto;
		padding: 0.6rem 16px;
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
	}
	.brand {
		display: inline-flex;
		align-items: center;
		gap: 0.5rem;
		font-family: var(--font-display);
		font-weight: 700;
		font-size: 1.2rem;
		letter-spacing: -0.005em;
		color: var(--text);
		text-decoration: none;
		flex-shrink: 0;
	}
	.open {
		color: var(--accent);
	}
	.account {
		display: flex;
		align-items: center;
		gap: 0.6rem;
		min-width: 0;
	}
	.email {
		color: var(--text-muted);
		font-size: 0.875rem;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		min-width: 0;
	}
	nav {
		max-width: 880px;
		margin: 0 auto;
		padding: 0 16px;
		display: flex;
		gap: 0.25rem;
	}
	nav a {
		padding: 0.6rem 0.9rem;
		color: var(--text-muted);
		text-decoration: none;
		font-weight: 600;
		border-bottom: 3px solid transparent;
	}
	nav a[aria-current='page'] {
		color: var(--accent);
		border-bottom-color: var(--accent);
	}
	.mock-note {
		background: var(--warn-bg);
		color: var(--warn);
		text-align: center;
		font-size: 0.85rem;
		padding: 0.35rem 16px;
	}
	.site-footer {
		max-width: 880px;
		margin: 0 auto;
		padding: 1rem 16px 2rem;
		display: flex;
		flex-wrap: wrap;
		gap: 1.25rem;
		font-size: 0.875rem;
		border-top: 1px solid var(--border);
	}
	.site-footer a {
		color: var(--text-muted);
	}
	@media (max-width: 420px) {
		.email {
			display: none;
		}
	}
</style>
