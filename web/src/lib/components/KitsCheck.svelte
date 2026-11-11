<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/**
	 * The kit-group check: one card per group the engine made, each a sample
	 * of people. The user taps anyone who doesn't belong, then says whether
	 * the groups match the kits: one group per kit, two groups that are the
	 * same kit (merged), or one group with two kits in it (split, and shown
	 * again).
	 */
	import type { KitsAnswer, KitsQuestion, KitStructure } from '#lib/types.ts';

	let {
		q,
		busy,
		marked = [],
		onanswer
	}: {
		q: KitsQuestion;
		busy: boolean;
		/** People already tapped before a split, so they needn't be tapped again. */
		marked?: KitsAnswer['wrong'];
		onanswer: (a: KitsAnswer) => void;
	} = $props();

	const key = (groupId: string, personId: string) => `${groupId}/${personId}`;
	// Only those still in the same group: a split group's people are new.
	// svelte-ignore state_referenced_locally
	let wrong = $state<Record<string, boolean>>(
		Object.fromEntries(
			marked
				.filter((w) => q.groups.some((g) => g.id === w.groupId && g.people.some((p) => p.id === w.personId)))
				.map((w) => [key(w.groupId, w.personId), true])
		)
	);
	let kind = $state<KitStructure['kind'] | null>(null);
	let merge = $state<Record<string, boolean>>({});
	let split = $state<string | null>(null);

	const groupName = (i: number) => `Group ${i + 1}`;
	const wrongCount = (groupId: string) => Object.entries(wrong).filter(([k, v]) => v && k.startsWith(`${groupId}/`)).length;
	const merged = $derived(q.groups.filter((g) => merge[g.id]).map((g) => g.id));

	const structure = $derived<KitStructure | null>(
		kind === 'ok'
			? { kind: 'ok' }
			: kind === 'merge' && merged.length >= 2
				? { kind: 'merge', groups: merged }
				: kind === 'split' && split
					? { kind: 'split', group: split }
					: null
	);

	function send() {
		if (!structure) return;
		onanswer({
			check: 'kits',
			round: q.round,
			wrong: q.groups.flatMap((g) =>
				g.people.filter((p) => wrong[key(g.id, p.id)]).map((p) => ({ groupId: g.id, personId: p.id }))
			),
			structure
		});
	}
</script>

<p>
	We sorted the people on the pitch into groups by kit. <strong>Tap anyone who is in the wrong group</strong>, or who
	isn't a player in kit (a referee, a coach, someone watching).
</p>

<div class="groups">
	{#each q.groups as g, i (g.id)}
		<section class="group">
			<h3>
				{groupName(i)}
				{#if wrongCount(g.id)}<span class="muted small">· {wrongCount(g.id)} marked</span>{/if}
			</h3>
			<div class="people">
				{#each g.people as p, n (p.id)}
					<button
						type="button"
						class="person"
						class:wrong={wrong[key(g.id, p.id)]}
						aria-pressed={wrong[key(g.id, p.id)] === true}
						aria-label="{groupName(i)}, person {n + 1}{wrong[key(g.id, p.id)] ? ', marked as not belonging' : ''}"
						disabled={busy}
						onclick={() => (wrong[key(g.id, p.id)] = !wrong[key(g.id, p.id)])}
					>
						{#if p.imageUrl}<img src={p.imageUrl} alt="" loading="lazy" />{/if}
						{#if wrong[key(g.id, p.id)]}<span class="cross" aria-hidden="true">✕</span>{/if}
					</button>
				{/each}
			</div>
		</section>
	{/each}
</div>

<fieldset class="structure" disabled={busy}>
	<legend>Now, looking at the groups as a whole:</legend>
	<label><input type="radio" name="structure" value="ok" bind:group={kind} /> Every kit has exactly one group</label>

	<label><input type="radio" name="structure" value="merge" bind:group={kind} /> Two groups are the same kit</label>
	{#if kind === 'merge'}
		<div class="pick" role="group" aria-label="Which groups are the same kit?">
			{#each q.groups as g, i (g.id)}
				<label><input type="checkbox" bind:checked={merge[g.id]} /> {groupName(i)}</label>
			{/each}
			{#if merged.length < 2}<span class="muted small">Pick the groups that are the same kit.</span>{/if}
		</div>
	{/if}

	{#if q.canSplit}
		<label><input type="radio" name="structure" value="split" bind:group={kind} /> One group has two kits in it</label>
		{#if kind === 'split'}
			<div class="pick" role="group" aria-label="Which group has two kits in it?">
				{#each q.groups as g, i (g.id)}
					<label><input type="radio" name="split" value={g.id} bind:group={split} /> {groupName(i)}</label>
				{/each}
				<span class="muted small">We'll split it and show you the groups again.</span>
			</div>
		{/if}
	{/if}
</fieldset>

<div class="actions">
	<button class="btn btn-primary" onclick={send} disabled={busy || !structure}>
		{busy ? 'Saving…' : kind === 'split' ? 'Split that group' : 'Done'}
	</button>
	{#if !kind}<span class="muted small">Answer the question above first.</span>{/if}
</div>

<style>
	.groups {
		display: grid;
		gap: 0.9rem;
	}
	.group {
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		padding: 0.6rem 0.75rem 0.75rem;
		background: var(--surface-2);
	}
	h3 {
		margin: 0 0 0.5rem;
		font-size: 1rem;
	}
	.people {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(56px, 1fr));
		gap: 6px;
	}
	.person {
		position: relative;
		padding: 0;
		border: 3px solid transparent;
		border-radius: 8px;
		background: var(--pitch);
		aspect-ratio: 2 / 3;
		overflow: hidden;
		cursor: pointer;
	}
	.person img {
		display: block;
		width: 100%;
		height: 100%;
		object-fit: cover;
	}
	.person.wrong {
		border-color: var(--danger);
	}
	.person.wrong img {
		opacity: 0.45;
	}
	.cross {
		position: absolute;
		inset: 0;
		display: grid;
		place-items: center;
		font-size: 1.6rem;
		font-weight: 700;
		color: #ffffff;
		text-shadow: 0 0 4px #000;
	}
	.structure {
		margin: 1rem 0 0;
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		display: grid;
		gap: 0.4rem;
	}
	.structure legend {
		font-weight: 600;
		padding: 0 0.3rem;
	}
	.pick {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.25rem 1.1rem;
		margin: 0 0 0.3rem 1.6rem;
	}
	.actions {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.5rem;
		margin-top: 0.9rem;
	}
</style>
