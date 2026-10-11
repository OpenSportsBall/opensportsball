<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { ApiError } from '#lib/api.ts';

	let { error, retry }: { error: unknown; retry?: () => void } = $props();

	const message: string = $derived(
		error instanceof Error ? error.message : typeof error === 'string' ? error : 'Something went wrong.'
	);
	const code = $derived(error instanceof ApiError && error.status > 0 ? `${error.code} (HTTP ${error.status})` : null);
</script>

<div class="error" role="alert">
	<div>
		<strong>{message}</strong>
		{#if code}<div class="code">Error code: {code}</div>{/if}
	</div>
	{#if retry}<button class="btn btn-small" onclick={retry}>Try again</button>{/if}
</div>

<style>
	.error {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
		padding: 0.75rem 1rem;
		border-radius: var(--radius);
		border: 1px solid var(--danger-border);
		background: var(--danger-bg);
		color: var(--danger);
		margin-bottom: 1rem;
	}
	.code {
		font-size: 0.8rem;
		font-family: var(--mono);
		opacity: 0.85;
	}
</style>
