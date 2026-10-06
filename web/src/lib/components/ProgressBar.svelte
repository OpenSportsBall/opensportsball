<!-- SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/** `value` in [0, 1]; null draws an indeterminate (unknown total) bar. */
	let { value, label }: { value: number | null; label: string } = $props();
</script>

<div
	class="track"
	role="progressbar"
	aria-label={label}
	aria-valuemin={0}
	aria-valuemax={100}
	aria-valuenow={value == null ? undefined : Math.round(value * 100)}
>
	{#if value == null}
		<div class="fill unknown"></div>
	{:else}
		<div class="fill" class:done={value >= 1} style:width="{value * 100}%"></div>
	{/if}
</div>

<style>
	.track {
		height: 10px;
		border-radius: 999px;
		background: var(--track);
		overflow: hidden;
	}
	.fill {
		height: 100%;
		border-radius: 999px;
		background: var(--info);
		transition: width 0.6s ease;
	}
	.fill.done {
		background: var(--ok);
	}
	.fill.unknown {
		width: 30%;
		background: var(--warn);
		opacity: 0.6;
		animation: slide 1.6s ease-in-out infinite;
	}
	@keyframes slide {
		from {
			transform: translateX(-100%);
		}
		to {
			transform: translateX(340%);
		}
	}
	@media (prefers-reduced-motion: reduce) {
		.fill {
			transition: none;
		}
		.fill.unknown {
			animation: none;
		}
	}
</style>
