<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { formatDateTime } from '#lib/format.ts';
	import { parseGrantFragment, type GrantLink } from '#lib/grant.ts';

	// Opened on the phone itself, often by someone not signed in: no sign-in
	// here. Everything it needs is in the fragment (docs/API.md).
	let link = $state<GrantLink | null>(null);
	let checked = $state(false);

	const expired = $derived(link !== null && Date.parse(link.expiresAt) < Date.now());

	onMount(() => {
		link = parseGrantFragment(window.location.hash);
		checked = true;
	});
</script>

<svelte:head><title>Upload permission · OpenSportsBall</title></svelte:head>

{#if checked}
	<section class="card stack grant">
		{#if !link}
			<h1>This link is not complete</h1>
			<p>Copy the whole link again from the game's page on the website.</p>
		{:else if expired}
			<h1>This link has expired</h1>
			<p>Ask whoever sent it for a new one from the game's page on the website.</p>
		{:else}
			<h1>Upload this phone's footage</h1>
			<p>
				This lets the OpenSportsBall app on this phone upload what it recorded for one game, into the account of the
				person who sent the link.
			</p>
			<a class="btn btn-primary open" href={link.appUri}>Open in the app</a>
			<p class="muted small">
				Works on one phone, until {formatDateTime(link.expiresAt)}. Nothing happens if you do not have the app, or
				it has no recording of that game.
			</p>
		{/if}
	</section>
{/if}

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
