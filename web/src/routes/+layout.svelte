<!-- SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import '../app.css';
	import { onMount, type Snippet } from 'svelte';
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import { session } from '#lib/session.svelte.ts';

	let { children }: { children: Snippet } = $props();

	onMount(() => {
		void session.init();
	});

	const path = $derived(page.url.pathname);
</script>

<header class="site-header">
	<div class="bar">
		<a class="brand" href={resolve('/')}>
			<svg viewBox="0 0 32 32" width="26" height="26" aria-hidden="true">
				<circle cx="16" cy="16" r="14" fill="var(--accent)" />
				<circle cx="16" cy="16" r="9" fill="none" stroke="var(--surface)" stroke-width="2.5" />
				<path d="M13 12l7 4-7 4z" fill="var(--surface)" />
			</svg>
			<span>SportsBallVideo</span>
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
		</nav>
	{/if}
</header>

{#if session.mock && session.status === 'ready'}
	<div class="mock-note">Mock mode: sample data, no AWS. Nothing here is real.</div>
{/if}

<main class="container">
	{#if session.status === 'loading'}
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
		font-weight: 700;
		font-size: 1.1rem;
		color: var(--text);
		text-decoration: none;
		flex-shrink: 0;
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
	@media (max-width: 420px) {
		.email {
			display: none;
		}
	}
</style>
