<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { session } from '#lib/session.svelte.ts';

	$effect(() => {
		if (session.status === 'ready' && session.signedIn) void goto(resolve('/games'), { replace: true });
	});
</script>

<svelte:head><title>OpenSportsBall</title></svelte:head>

{#if !session.signedIn}
	<section class="hero">
		<h1>Film the whole game with two phones</h1>
		<p class="lead">
			OpenSportsBall is a free, open-source way to record youth soccer. Two phones on tripods cover the
			full field. When you get home, they upload the footage on Wi-Fi and it is turned into one game video.
		</p>
		<button class="btn btn-primary big" onclick={() => session.signIn('/games')}>Sign in</button>
		<p class="muted small">New here? Choose "Sign up" on the next screen to create an account.</p>
	</section>

	<section class="steps">
		<div class="card">
			<h2>1. Link your phones</h2>
			<p class="muted">Scan a QR code from this site with each phone. You only do this once.</p>
		</div>
		<div class="card">
			<h2>2. Record the game</h2>
			<p class="muted">One phone is the main camera, the other covers the far side. Hit record on the main phone.</p>
		</div>
		<div class="card">
			<h2>3. Upload on Wi-Fi</h2>
			<p class="muted">The phones upload by themselves. Follow progress here on the Games page.</p>
		</div>
	</section>
{/if}

<style>
	.hero {
		padding: 1.5rem 0 2rem;
		max-width: 38rem;
	}
	.hero h1 {
		font-size: clamp(1.7rem, 6vw, 2.4rem);
	}
	.lead {
		font-size: 1.1rem;
		margin-bottom: 1.25rem;
	}
	.big {
		min-width: 10rem;
		font-size: 1.05rem;
		margin-bottom: 0.75rem;
	}
	.steps {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
		gap: 0.75rem;
	}
	.steps h2 {
		font-size: 1.05rem;
	}
	.steps p {
		margin: 0;
	}
</style>
