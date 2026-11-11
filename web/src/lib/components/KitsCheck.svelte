<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/**
	 * The kit-group check, from the engine's own question (engine-questions),
	 * asked the way the Mac app asks it: one card per group, each a sample
	 * of people. The user taps anyone who doesn't belong, says what each
	 * group is (a kit, the keepers or referee, not a kit), then whether the
	 * groups match the kits: one group per kit, groups that are the same kit
	 * (merged), or one group with two kits in it (split, and shown again).
	 * There is no "which is your team": the camera follows play.
	 */
	import type { KitGroup, KitsAnswer, KitsQuestion } from '#lib/types.ts';

	type Role = 'kit' | 'keeperOrReferee' | 'notKit';
	type Structure = 'ok' | 'merge' | 'split';

	let {
		q,
		busy,
		marked = {},
		onanswer
	}: {
		q: KitsQuestion;
		busy: boolean;
		/** People already tapped before a split, so they needn't be tapped again. */
		marked?: Record<string, string[]>;
		onanswer: (a: KitsAnswer) => void;
	} = $props();

	// The page makes a new one of these for each round.
	// svelte-ignore state_referenced_locally
	const groups = [...q.groups].sort((a, b) => b.people - a.people);
	const name = (g: KitGroup) => `Group ${groups.indexOf(g) + 1}`;
	const proposedRole = (g: KitGroup): Role => (g.proposed === 'A' || g.proposed === 'B' ? 'kit' : g.proposed === 'keeperOrReferee' ? 'keeperOrReferee' : 'notKit');

	// Only crops still shown in the same group: a split group's people are new.
	// svelte-ignore state_referenced_locally
	let tapped = $state<Record<string, boolean>>(
		Object.fromEntries(
			groups.flatMap((g) => (marked[String(g.component)] ?? []).filter((id) => g.crops.some((c) => c.id === id)).map((id) => [id, true]))
		)
	);
	let roles = $state<Record<number, Role>>({});
	let structure = $state<Structure | null>(null);
	let merge = $state<Record<number, boolean>>({});
	let split = $state<number | null>(null);

	const role = (g: KitGroup) => roles[g.component] ?? proposedRole(g);
	const tappedIn = (g: KitGroup) => g.crops.filter((c) => tapped[c.id]).map((c) => c.id);
	const merged = $derived(groups.filter((g) => merge[g.component]).map((g) => g.component));
	const ready = $derived(structure === 'ok' || (structure === 'merge' && merged.length >= 2) || (structure === 'split' && split !== null));

	function send() {
		if (!ready) return;
		const changedRoles = Object.keys(roles).length > 0;
		const notKit = groups.filter((g) => role(g) === 'notKit').map((g) => g.component);
		onanswer({
			question: 'kits',
			round: q.round,
			tapped: Object.fromEntries(groups.filter((g) => tappedIn(g).length).map((g) => [String(g.component), tappedIn(g)])),
			...(structure === 'merge' ? { merge: [merged] } : {}),
			...(structure === 'split' && split !== null ? { split } : {}),
			// Only when changed: otherwise the engine keeps its own guess.
			...(changedRoles
				? { keeperOrReferee: groups.filter((g) => role(g) === 'keeperOrReferee').map((g) => g.component), notKit }
				: {})
		});
	}
</script>

{#if q.problem}<p class="problem">We couldn't use that answer: {q.problem}.</p>{/if}

<p>
	We sorted the people on the pitch into groups by what they wear. <strong>Tap anyone who is in the wrong group</strong>.
	Then check what each group is.
</p>

<div class="groups">
	{#each groups as g (g.component)}
		<section class="group">
			<div class="group-head">
				<h3>
					{name(g)}
					{#if tappedIn(g).length}<span class="muted small">· {tappedIn(g).length} marked</span>{/if}
				</h3>
				<fieldset class="role" disabled={busy}>
					<legend class="sr-only">What {name(g)} is</legend>
					{#each [['kit', 'A kit'], ['keeperOrReferee', 'Keepers or referee'], ['notKit', 'Not a kit']] as [value, text] (value)}
						<label class:on={role(g) === value}>
							<input
								type="radio"
								name="role-{g.component}"
								{value}
								checked={role(g) === value}
								onchange={() => (roles[g.component] = value as Role)}
							/>
							{text}
						</label>
					{/each}
				</fieldset>
			</div>
			<div class="people">
				{#each g.crops as c, n (c.id)}
					<button
						type="button"
						class="person"
						class:wrong={tapped[c.id]}
						aria-pressed={tapped[c.id] === true}
						aria-label="{name(g)}, person {n + 1}{tapped[c.id] ? ', marked as not belonging' : ''}"
						disabled={busy}
						onclick={() => (tapped[c.id] = !tapped[c.id])}
					>
						{#if c.imageUrl}<img src={c.imageUrl} alt="" loading="lazy" />{/if}
						{#if tapped[c.id]}<span class="cross" aria-hidden="true">✕</span>{/if}
					</button>
				{/each}
			</div>
		</section>
	{/each}
</div>

<fieldset class="structure" disabled={busy}>
	<legend>Now, looking at the groups as a whole:</legend>
	<label><input type="radio" name="structure" value="ok" bind:group={structure} /> Every kit has exactly one group</label>

	<label><input type="radio" name="structure" value="merge" bind:group={structure} /> Some groups are the same kit</label>
	{#if structure === 'merge'}
		<div class="pick" role="group" aria-label="Which groups are the same kit?">
			{#each groups as g (g.component)}
				<label><input type="checkbox" bind:checked={merge[g.component]} /> {name(g)}</label>
			{/each}
			{#if merged.length < 2}<span class="muted small">Pick the groups that are the same kit.</span>{/if}
		</div>
	{/if}

	{#if q.splitAllowed}
		<label><input type="radio" name="structure" value="split" bind:group={structure} /> One group has two kits in it</label>
		{#if structure === 'split'}
			<div class="pick" role="group" aria-label="Which group has two kits in it?">
				{#each groups as g (g.component)}
					<label><input type="radio" name="split" value={g.component} bind:group={split} /> {name(g)}</label>
				{/each}
				<span class="muted small">We'll sort the groups again and show you.</span>
			</div>
		{/if}
	{/if}
</fieldset>

<div class="actions">
	<button class="btn btn-primary" onclick={send} disabled={busy || !ready}>
		{busy ? 'Saving…' : structure === 'split' ? 'Split that group' : 'Done'}
	</button>
	{#if !structure}<span class="muted small">Answer the question above first.</span>{/if}
</div>

<style>
	.problem {
		background: var(--danger-bg);
		color: var(--danger);
		border-radius: 8px;
		padding: 0.5rem 0.75rem;
	}
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
	.group-head {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		align-items: center;
		gap: 0.4rem 1rem;
		margin-bottom: 0.5rem;
	}
	h3 {
		margin: 0;
		font-size: 1rem;
	}
	.role {
		display: flex;
		flex-wrap: wrap;
		border: 0;
		margin: 0;
		padding: 0;
		gap: 0.25rem;
	}
	.role label {
		font-size: 0.85rem;
		padding: 0.2rem 0.6rem;
		border: 1px solid var(--border-strong);
		border-radius: 999px;
		background: var(--surface);
		cursor: pointer;
	}
	.role label.on {
		background: var(--accent);
		border-color: var(--accent);
		color: var(--accent-text);
		font-weight: 600;
	}
	.role input {
		position: absolute;
		opacity: 0;
		pointer-events: none;
	}
	.role label:focus-within {
		outline: 2px solid var(--focus);
		outline-offset: 2px;
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip-path: inset(50%);
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
