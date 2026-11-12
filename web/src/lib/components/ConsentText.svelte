<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/** The approved sharing wording (lib/consent.ts), drawn block by block. */
	import { consentBlocks, type ConsentBlock } from '#lib/consent.ts';

	const blocks = consentBlocks();
	type Group = { list: false; block: ConsentBlock } | { list: true; items: ConsentBlock[] };
	// Bullets that follow each other make one list.
	const groups = blocks.reduce<Group[]>((out, b) => {
		const last = out.at(-1);
		if (b.kind === 'bullet' && last?.list) last.items.push(b);
		else out.push(b.kind === 'bullet' ? { list: true, items: [b] } : { list: false, block: b });
		return out;
	}, []);
</script>

{#snippet text(b: ConsentBlock)}
	{#each b.runs as r, i (i)}{#if r.bold}<strong>{r.text}</strong>{:else}{r.text}{/if}{/each}
{/snippet}

<div class="consent">
	{#each groups as g, i (i)}
		{#if g.list}
			<ul>
				{#each g.items as b, j (j)}<li>{@render text(b)}</li>{/each}
			</ul>
		{:else if g.block.kind === 'heading'}
			<h3>{@render text(g.block)}</h3>
		{:else if g.block.kind === 'link'}
			<p><a href={g.block.url} target="_blank" rel="noopener">{@render text(g.block)}</a></p>
		{:else}
			<p>{@render text(g.block)}</p>
		{/if}
	{/each}
</div>

<style>
	.consent {
		font-size: 0.92rem;
	}
	h3 {
		margin: 0.5rem 0 0.4rem;
		font-size: 1rem;
	}
	p,
	ul {
		margin: 0 0 0.5rem;
	}
	ul {
		padding-left: 1.2rem;
	}
</style>
