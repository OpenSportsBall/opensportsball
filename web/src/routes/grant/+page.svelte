<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { ApiError } from '#lib/api.ts';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import { formatDateTime } from '#lib/format.ts';
	import { parseGrantFragment, type GrantLink } from '#lib/grant.ts';
	import { session } from '#lib/session.svelte.ts';

	// Opened on the phone itself, often by someone not signed in: no sign-in
	// here. The link holds the ticket; the API says which game it is for.
	type State =
		| { kind: 'loading' }
		| { kind: 'broken' }
		| { kind: 'missing' }
		| { kind: 'expired' }
		| { kind: 'error'; error: unknown }
		| { kind: 'ready'; link: GrantLink; used: boolean };
	let view = $state<State>({ kind: 'loading' });

	async function load() {
		const f = parseGrantFragment(window.location.hash);
		if (!f) {
			view = { kind: 'broken' };
			return;
		}
		if ('link' in f) {
			// A long link from before 2026-10-29 carries everything itself.
			view = Date.parse(f.link.expiresAt) < Date.now() ? { kind: 'expired' } : { kind: 'ready', link: f.link, used: false };
			return;
		}
		view = { kind: 'loading' };
		try {
			await session.init();
			const t = await session.api.lookupGrantTicket(f.ticket);
			view = { kind: 'ready', link: t, used: t.used };
		} catch (e) {
			if (e instanceof ApiError && e.status === 404) view = { kind: 'missing' };
			else if (e instanceof ApiError && e.status === 410) view = { kind: 'expired' };
			else view = { kind: 'error', error: e };
		}
	}

	onMount(() => {
		void load();
		// Another link opened in this same tab changes only the fragment.
		const again = () => void load();
		window.addEventListener('hashchange', again);
		return () => window.removeEventListener('hashchange', again);
	});
</script>

<svelte:head><title>Upload permission · OpenSportsBall</title></svelte:head>

<section class="card stack grant">
	{#if view.kind === 'loading'}
		<p class="muted">Checking the link…</p>
	{:else if view.kind === 'broken'}
		<h1>This link is not complete</h1>
		<p>Copy the whole link again from the game's page on the website.</p>
	{:else if view.kind === 'missing'}
		<h1>This link does not work</h1>
		<p>Ask whoever sent it for a new one from the game's page on the website.</p>
	{:else if view.kind === 'expired'}
		<h1>This link has expired</h1>
		<p>Ask whoever sent it for a new one from the game's page on the website.</p>
	{:else if view.kind === 'error'}
		<h1>Could not check this link</h1>
		<ErrorBanner error={view.error} retry={() => void load()} />
	{:else}
		<h1>Upload this phone's footage</h1>
		<p>
			This lets the OpenSportsBall app on this phone upload what it recorded for one game, into the account of the
			person who sent the link.
		</p>
		<a class="btn btn-primary open" href={view.link.appUri}>Open in the app</a>
		{#if view.used}
			<p class="muted small">
				This link has already been used on one phone. Opening it again on that phone is fine; another phone needs a
				new link.
			</p>
		{:else}
			<p class="muted small">
				Works on one phone, until {formatDateTime(view.link.expiresAt)}. Nothing happens if you do not have the app, or
				it has no recording of that game.
			</p>
		{/if}
	{/if}
</section>

<style>
	.grant {
		max-width: 520px;
		margin: 1rem auto;
		text-align: center;
	}
	.grant h1 {
		font-size: clamp(1.25rem, 5vw, 1.6rem);
	}
	.open {
		display: inline-block;
		text-decoration: none;
		font-size: 1.05rem;
		padding: 0.75rem 1.4rem;
	}
</style>
