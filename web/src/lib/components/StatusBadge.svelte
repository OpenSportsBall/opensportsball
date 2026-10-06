<!-- SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { statusLabel } from '#lib/format.ts';

	let { status }: { status: string } = $props();
</script>

<span class="badge {status}">{statusLabel(status)}</span>

<style>
	.badge {
		display: inline-block;
		padding: 0.15rem 0.6rem;
		border-radius: 999px;
		font-size: 0.8rem;
		font-weight: 600;
		white-space: nowrap;
		background: var(--surface-2);
		color: var(--text-muted);
	}
	.ready {
		background: var(--ok-bg);
		color: var(--ok);
	}
	.uploading {
		background: var(--info-bg);
		color: var(--info);
	}
	.waiting_for_manifest {
		background: var(--warn-bg);
		color: var(--warn);
	}
</style>
