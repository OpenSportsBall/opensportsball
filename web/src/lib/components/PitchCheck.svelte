<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/**
	 * The pitch check, from the engine's own question (engine-questions):
	 * the empty pitch with the fitted lines drawn on it. The user approves
	 * it, or drags the named points to where they really are (or says a
	 * point can't be seen) and sends them for a refit. The engine works in
	 * panorama degrees; `panorama` says how they map to the picture's pixels.
	 */
	import type { PitchAnswer, PitchPointAnswer, PitchQuestion } from '#lib/types.ts';

	let { q, busy, onanswer }: { q: PitchQuestion; busy: boolean; onanswer: (a: PitchAnswer) => void } = $props();

	// The page makes a new one of these for each round, so the question's
	// values are read once.
	// svelte-ignore state_referenced_locally
	const pano = q.panorama ?? null;
	const width = pano ? (pano.yawRange[1] - pano.yawRange[0]) / pano.degPerPx : 0;
	const height = pano ? (pano.pitchRange[1] - pano.pitchRange[0]) / pano.degPerPx : 0;
	const x = (yaw: number) => (yaw - pano!.yawRange[0]) / pano!.degPerPx;
	const y = (pitch: number) => (pitch - pano!.pitchRange[0]) / pano!.degPerPx;
	const round3 = (v: number) => Math.round(v * 1000) / 1000;

	// svelte-ignore state_referenced_locally
	const mustMark = q.approveAllowed === false;
	let marking = $state(mustMark && pano !== null);
	// svelte-ignore state_referenced_locally
	let points = $state(
		Object.entries(q.points).map(([name, p]) => ({ name, yaw: p.yaw, pitch: p.pitch, moved: false, skipped: false }))
	);
	let selected = $state<string | null>(null);
	let shownWidth = $state(0);
	let svg = $state<SVGSVGElement | null>(null);

	/** Picture pixels per screen pixel, so handles stay a finger wide. */
	const scale = $derived(shownWidth > 0 && width > 0 ? width / shownWidth : 2);
	const d = (line: [number, number][]) => line.map(([yaw, pitch], i) => `${i ? 'L' : 'M'}${x(yaw)} ${y(pitch)}`).join(' ');
	const changed = $derived(points.some((p) => p.moved || p.skipped));
	const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
	const label = (name: string) => name.charAt(0).toUpperCase() + name.slice(1);

	function place(p: (typeof points)[number], px: number, py: number) {
		p.yaw = round3(pano!.yawRange[0] + clamp(px, 0, width) * pano!.degPerPx);
		p.pitch = round3(pano!.pitchRange[0] + clamp(py, 0, height) * pano!.degPerPx);
		p.moved = true;
		p.skipped = false;
	}

	let dragging = $state<string | null>(null);

	function down(e: PointerEvent, name: string) {
		if (busy) return;
		selected = dragging = name;
		(e.currentTarget as Element).setPointerCapture(e.pointerId);
		e.preventDefault();
	}

	function move(e: PointerEvent, name: string) {
		if (dragging !== name) return;
		const at = new DOMPoint(e.clientX, e.clientY).matrixTransform(svg!.getScreenCTM()!.inverse());
		place(points.find((k) => k.name === name)!, at.x, at.y);
	}

	function key(e: KeyboardEvent, name: string) {
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
		const p = points.find((k) => k.name === name)!;
		place(p, x(p.yaw) + by[0], y(p.pitch) + by[1]);
		selected = name;
	}

	const approve = () => onanswer({ question: 'pitch', round: q.round, approve: true });
	const send = () =>
		onanswer({
			question: 'pitch',
			round: q.round,
			points: Object.fromEntries(
				points.map((p): [string, PitchPointAnswer] => [
					p.name,
					p.skipped ? { skipped: true } : p.moved ? { yaw: p.yaw, pitch: p.pitch } : { fromFit: true }
				])
			)
		});
</script>

{#if q.problem}<p class="problem">{label(q.problem)}.</p>{/if}

<p>
	{#if marking}
		Drag each numbered point to where it really is on the pitch. Leave the ones that are already right. If you can't
		see one, tick <strong>Can't see it</strong>.
	{:else}
		Here is the pitch with our best guess at its lines drawn in red. Do the red lines sit on the painted lines?
	{/if}
</p>
{#if mustMark}
	<p class="muted small">
		The two phones' views couldn't be matched up for this game, so the lines are only roughly placed until you mark
		the points.
	</p>
{/if}

<div class="frame" class:marking>
	{#if marking && pano}
		<div class="picture" bind:clientWidth={shownWidth}>
			<svg bind:this={svg} viewBox="0 0 {width} {height}" role="group" aria-label="The pitch, with our fitted lines and the points you can move">
				{#if q.backgroundUrl}<image href={q.backgroundUrl} {width} {height} />{/if}
				{#each q.lines as line, i (i)}
					<path class="fit halo" d={d(line)} stroke-width={5 * scale} />
					<path class="fit" d={d(line)} stroke-width={2.5 * scale} />
				{/each}
				{#each points as p, i (p.name)}
					{#if !p.skipped}
						<g
							class="handle"
							class:selected={selected === p.name}
							class:moved={p.moved}
							transform="translate({x(p.yaw)} {y(p.pitch)})"
							role="button"
							tabindex="0"
							aria-label="{label(p.name)}: drag, or move with the arrow keys"
							onpointerdown={(e) => down(e, p.name)}
							onpointermove={(e) => move(e, p.name)}
							onpointerup={() => (dragging = null)}
							onpointercancel={() => (dragging = null)}
							onkeydown={(e) => key(e, p.name)}
							onfocus={() => (selected = p.name)}
						>
							<circle class="grab" r={22 * scale} />
							<circle class="ring" r={11 * scale} stroke-width={2.5 * scale} />
							<circle class="dot" r={2 * scale} />
							<text y={-16 * scale} font-size={13 * scale} stroke-width={3 * scale}>{i + 1}</text>
						</g>
					{/if}
				{/each}
			</svg>
		</div>
	{:else if q.overlayUrl}
		<img class="overlay" src={q.overlayUrl} alt="The pitch with our fitted lines drawn on it in red" />
	{/if}
</div>

{#if marking}
	<p class="muted small swipe">Swipe the picture sideways to reach the rest of the pitch.</p>
	<ol class="points">
		{#each points as p (p.name)}
			<li class:selected={selected === p.name}>
				<button type="button" class="name" onclick={() => (selected = p.name)}>{label(p.name)}</button>
				{#if p.moved && !p.skipped}<span class="muted small">moved</span>{/if}
				<label class="small">
					<input type="checkbox" bind:checked={p.skipped} disabled={busy} /> Can't see it
				</label>
			</li>
		{/each}
	</ol>
{/if}

<div class="actions">
	{#if marking}
		<button class="btn btn-primary" onclick={send} disabled={busy || !changed}>
			{busy ? 'Sending…' : 'Use these points'}
		</button>
		{#if !mustMark}<button class="btn" onclick={() => (marking = false)} disabled={busy}>Back</button>{/if}
		{#if !changed}<span class="muted small">Move a point first.</span>{/if}
	{:else}
		{#if !mustMark}
			<button class="btn btn-primary" onclick={approve} disabled={busy}>
				{busy ? 'Saving…' : 'Yes, the lines are right'}
			</button>
		{/if}
		{#if pano}
			<button class="btn" onclick={() => (marking = true)} disabled={busy}>No, let me fix them</button>
		{/if}
	{/if}
</div>

<style>
	.problem {
		background: var(--danger-bg);
		color: var(--danger);
		border-radius: 8px;
		padding: 0.5rem 0.75rem;
	}
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
	svg,
	.overlay {
		display: block;
		width: 100%;
		height: auto;
	}
	svg {
		touch-action: pan-x pan-y;
	}
	.fit {
		fill: none;
		stroke: #ff5a4d;
		stroke-linecap: round;
		stroke-dasharray: 2 3;
	}
	.fit.halo {
		stroke: rgb(0 0 0 / 45%);
		stroke-dasharray: none;
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
	.handle.moved .ring {
		stroke: #7fd4ff;
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
		margin-right: 0.5rem;
	}
	.points label {
		margin-left: 0.5rem;
	}
	.actions {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.5rem;
		margin-top: 0.9rem;
	}
</style>
