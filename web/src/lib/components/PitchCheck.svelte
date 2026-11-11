<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/**
	 * The pitch check: the engine's picture of the pitch with its fitted
	 * lines drawn on it. The user approves it, or drags the named points to
	 * where they really are (or says a point can't be seen) and sends them
	 * for a refit. Everything is in the picture's own pixels.
	 */
	import type { PitchAnswer, PitchQuestion } from '#lib/types.ts';

	let { q, busy, onanswer }: { q: PitchQuestion; busy: boolean; onanswer: (a: PitchAnswer) => void } = $props();

	let marking = $state(false);
	// Each question (round) starts from the engine's points: the page makes
	// a new one of these for each round.
	// svelte-ignore state_referenced_locally
	let points = $state(q.keypoints.map((k) => ({ ...k, skipped: false })));
	let selected = $state<string | null>(null);
	// svelte-ignore state_referenced_locally
	let paint = $state(q.paint?.choice);
	let shownWidth = $state(0);
	let svg = $state<SVGSVGElement | null>(null);

	/** Picture pixels per screen pixel, so handles stay a finger wide. */
	const scale = $derived(shownWidth > 0 ? q.width / shownWidth : 2);
	const d = (line: [number, number][]) => line.map(([x, y], i) => `${i ? 'L' : 'M'}${x} ${y}`).join(' ');
	const moved = $derived(points.some((p, i) => p.skipped || p.x !== q.keypoints[i].x || p.y !== q.keypoints[i].y));

	const clamp = (v: number, max: number) => Math.min(max, Math.max(0, v));

	function toPicture(e: PointerEvent): [number, number] {
		const m = svg!.getScreenCTM()!.inverse();
		const p = new DOMPoint(e.clientX, e.clientY).matrixTransform(m);
		return [clamp(p.x, q.width), clamp(p.y, q.height)];
	}

	let dragging = $state<string | null>(null);

	function down(e: PointerEvent, id: string) {
		if (busy) return;
		selected = dragging = id;
		(e.currentTarget as Element).setPointerCapture(e.pointerId);
		e.preventDefault();
	}

	function move(e: PointerEvent, id: string) {
		if (dragging !== id) return;
		const p = points.find((k) => k.id === id)!;
		[p.x, p.y] = toPicture(e).map((v) => Math.round(v * 10) / 10) as [number, number];
		p.skipped = false;
	}

	function key(e: KeyboardEvent, id: string) {
		const step = (e.shiftKey ? 10 : 1) * scale;
		const delta: Record<string, [number, number]> = {
			ArrowLeft: [-step, 0],
			ArrowRight: [step, 0],
			ArrowUp: [0, -step],
			ArrowDown: [0, step]
		};
		const by = delta[e.key];
		if (!by || busy) return;
		e.preventDefault();
		const p = points.find((k) => k.id === id)!;
		p.x = Math.round(clamp(p.x + by[0], q.width) * 10) / 10;
		p.y = Math.round(clamp(p.y + by[1], q.height) * 10) / 10;
		p.skipped = false;
		selected = id;
	}

	const approve = () => onanswer({ check: 'pitch', round: q.round, approved: true, ...(paint ? { paint } : {}) });
	const send = () =>
		onanswer({
			check: 'pitch',
			round: q.round,
			approved: false,
			keypoints: points.map((p) => (p.skipped ? { id: p.id, skipped: true as const } : { id: p.id, x: p.x, y: p.y })),
			...(paint ? { paint } : {})
		});
</script>

<p>
	{#if marking}
		Drag each numbered point to where it really is on the pitch. If you can't see one, tick <strong>Can't see it</strong>.
	{:else}
		Here is the pitch with our best guess at its lines drawn in yellow. Do the yellow lines sit on the painted lines?
	{/if}
</p>

<div class="frame" class:marking>
	<div class="picture" bind:clientWidth={shownWidth}>
		<svg
			bind:this={svg}
			viewBox="0 0 {q.width} {q.height}"
			role="group"
			aria-label="The pitch, with our fitted lines{marking ? ' and the points you can move' : ''}"
		>
			{#if q.imageUrl}<image href={q.imageUrl} width={q.width} height={q.height} />{/if}
			{#each q.lines as line, i (i)}
				<path class="fit halo" d={d(line)} stroke-width={5 * scale} />
				<path class="fit" class:faded={marking} d={d(line)} stroke-width={2.5 * scale} />
			{/each}
			{#if marking}
				{#each points as p, i (p.id)}
					{#if !p.skipped}
						<g
							class="handle"
							class:selected={selected === p.id}
							transform="translate({p.x} {p.y})"
							role="button"
							tabindex="0"
							aria-label="{p.label}: drag, or move with the arrow keys"
							onpointerdown={(e) => down(e, p.id)}
							onpointermove={(e) => move(e, p.id)}
							onpointerup={() => (dragging = null)}
							onpointercancel={() => (dragging = null)}
							onkeydown={(e) => key(e, p.id)}
							onfocus={() => (selected = p.id)}
						>
							<circle class="grab" r={22 * scale} />
							<circle class="ring" r={11 * scale} stroke-width={2.5 * scale} />
							<circle class="dot" r={2 * scale} />
							<text y={-16 * scale} font-size={13 * scale} stroke-width={3 * scale}>{i + 1}</text>
						</g>
					{/if}
				{/each}
			{/if}
		</svg>
	</div>
</div>

{#if marking}
	<p class="muted small swipe">Swipe the picture sideways to reach the rest of the pitch.</p>
	<ol class="points">
		{#each points as p (p.id)}
			<li class:selected={selected === p.id}>
				<button type="button" class="name" onclick={() => (selected = p.id)}>{p.label}</button>
				<label class="small">
					<input type="checkbox" bind:checked={p.skipped} disabled={busy} /> Can't see it
				</label>
			</li>
		{/each}
	</ol>
{/if}

{#if q.paint}
	<fieldset class="paint">
		<legend>{q.paint.text}</legend>
		{#each q.paint.options as o (o.id)}
			<label><input type="radio" name="paint" value={o.id} bind:group={paint} disabled={busy} /> {o.label}</label>
		{/each}
	</fieldset>
{/if}

<div class="actions">
	{#if marking}
		<button class="btn btn-primary" onclick={send} disabled={busy || !moved}>
			{busy ? 'Sending…' : 'Use these points'}
		</button>
		<button class="btn" onclick={() => (marking = false)} disabled={busy}>Back</button>
		{#if !moved}<span class="muted small">Move a point first.</span>{/if}
	{:else}
		<button class="btn btn-primary" onclick={approve} disabled={busy}>
			{busy ? 'Saving…' : 'Yes, the lines are right'}
		</button>
		<button class="btn" onclick={() => (marking = true)} disabled={busy}>No, let me fix them</button>
	{/if}
</div>

<style>
	.frame {
		overflow-x: auto;
		border-radius: var(--radius-sm);
		border: 1px solid var(--border);
		background: #1d3b2a;
	}
	/* Wide enough to place a point with a finger; scrolls on a phone. */
	.frame.marking .picture {
		min-width: 720px;
	}
	svg {
		display: block;
		width: 100%;
		height: auto;
		touch-action: pan-x pan-y;
	}
	.fit {
		fill: none;
		stroke: #ffd21f;
		stroke-linecap: round;
	}
	.fit.halo {
		stroke: rgb(0 0 0 / 45%);
	}
	.fit.faded {
		stroke-dasharray: 2 3;
		opacity: 0.75;
	}
	.handle {
		cursor: grab;
		touch-action: none;
		outline: none;
	}
	.handle:active {
		cursor: grabbing;
	}
	.grab {
		fill: transparent;
	}
	.ring {
		fill: rgb(255 255 255 / 25%);
		stroke: #ffffff;
		filter: drop-shadow(0 0 1px #000);
	}
	.dot {
		fill: #d6301f;
	}
	.handle.selected .ring,
	.handle:focus-visible .ring {
		stroke: #ffd21f;
		fill: rgb(255 210 31 / 35%);
	}
	text {
		text-anchor: middle;
		font-weight: 700;
		fill: #ffffff;
		stroke: #000000;
		paint-order: stroke;
		pointer-events: none;
		user-select: none;
	}
	/* Only where the picture is wider than its frame. */
	.swipe {
		display: none;
		margin: 0.4rem 0 0;
	}
	@media (max-width: 800px) {
		.swipe {
			display: block;
		}
	}
	.points {
		margin: 0.75rem 0 0;
		padding-left: 1.6rem;
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
		gap: 0.25rem 1.5rem;
	}
	.points li {
		padding: 0.15rem 0.3rem;
		border-radius: 6px;
	}
	.points li.selected {
		background: var(--warn-bg);
	}
	.points li::marker {
		font-weight: 700;
	}
	.name {
		font: inherit;
		color: inherit;
		background: none;
		border: 0;
		padding: 0;
		cursor: pointer;
		margin-right: 0.75rem;
	}
	.paint {
		margin: 0.75rem 0 0;
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		display: flex;
		flex-wrap: wrap;
		gap: 0.25rem 1.25rem;
	}
	.actions {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.5rem;
		margin-top: 0.9rem;
	}
</style>
