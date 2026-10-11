<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { errorMessage } from '#lib/api.ts';
	import { session } from '#lib/session.svelte.ts';

	let error = $state<string | null>(null);

	onMount(async () => {
		await session.init();
		if (session.status !== 'ready' || !session.auth) return;
		const params = new URLSearchParams(window.location.search);
		const providerError = params.get('error_description') ?? params.get('error');
		if (providerError) {
			error = providerError;
			return;
		}
		try {
			const next = await session.auth.handleCallback();
			// Full load so the session state is rebuilt from the stored user.
			window.location.replace(next);
		} catch (e) {
			error = errorMessage(e);
		}
	});
</script>

<svelte:head><title>Signing in · OpenSportsBall</title></svelte:head>

{#if error}
	<div class="card stack">
		<h1>Sign-in didn't finish</h1>
		<p>{error}</p>
		<button class="btn btn-primary" onclick={() => session.signIn('/games')}>Try signing in again</button>
	</div>
{:else}
	<p class="muted">Signing you in…</p>
{/if}
