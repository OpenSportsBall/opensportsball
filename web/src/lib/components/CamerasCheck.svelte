<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/**
	 * Asked only when the two phones' views couldn't be matched up: the
	 * panorama drawn with each phone on the left. The one that shows the
	 * pitch in one piece tells the engine which phone is which.
	 */
	import type { CamerasAnswer, CamerasQuestion } from '#lib/types.ts';

	let { q, busy, onanswer }: { q: CamerasQuestion; busy: boolean; onanswer: (a: CamerasAnswer) => void } = $props();

	const choose = (leftPhone: 'main' | 'secondary') => onanswer({ question: 'cameras', round: q.round, leftPhone });
</script>

<p>
	We couldn't match up the two phones' views for this game, so we need your help with one thing first. Here is the
	pitch drawn both ways round. <strong>Which picture shows the pitch in one piece?</strong>
</p>

<div class="choices">
	{#each [['main', q.panoramas.mainLeftUrl], ['secondary', q.panoramas.secondaryLeftUrl]] as [phone, url], i (phone)}
		<figure>
			{#if url}<img src={url} alt="The pitch with the {phone === 'main' ? 'main' : 'second'} phone's view on the left" />{/if}
			<figcaption>
				<button class="btn btn-primary" onclick={() => choose(phone as 'main' | 'secondary')} disabled={busy}>
					{busy ? 'Saving…' : `Picture ${i + 1} is in one piece`}
				</button>
			</figcaption>
		</figure>
	{/each}
</div>

<style>
	.choices {
		display: grid;
		gap: 1rem;
	}
	figure {
		margin: 0;
	}
	img {
		display: block;
		width: 100%;
		height: auto;
		border-radius: var(--radius-sm);
		border: 1px solid var(--border);
		background: #1d3b2a;
	}
	figcaption {
		margin-top: 0.5rem;
	}
</style>
