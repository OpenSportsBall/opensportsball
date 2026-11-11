<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	/**
	 * The switch on a check: whether its result may be shared to improve the
	 * models. On by default, as in the Mac app; the approved wording opens
	 * beside it, and is put to the user to agree to before the first share
	 * (the check page).
	 */
	import ConsentText from '#lib/components/ConsentText.svelte';

	let { share = $bindable(), label, disabled = false }: { share: boolean; label: string; disabled?: boolean } = $props();
</script>

<div class="share">
	<label>
		<input type="checkbox" role="switch" bind:checked={share} {disabled} />
		{label}
	</label>
	<details>
		<summary class="small">What is shared, and what happens to it</summary>
		<ConsentText />
	</details>
</div>

<style>
	.share {
		margin-top: 0.9rem;
		padding: 0.6rem 0.75rem;
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		background: var(--surface-2);
	}
	label {
		display: flex;
		align-items: baseline;
		gap: 0.5rem;
		font-weight: 600;
	}
	details {
		margin-top: 0.3rem;
	}
	summary {
		cursor: pointer;
		color: var(--text-muted);
	}
</style>
