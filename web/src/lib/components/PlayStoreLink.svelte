<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { PLAY_STORE_URL } from '#lib/site.ts';

	let { primary = false }: { primary?: boolean } = $props();
</script>

<a class="btn" class:btn-primary={primary} href={PLAY_STORE_URL} target="_blank" rel="noopener">
	<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
		<path fill="currentColor" d="M5 3.2c0-.9 1-1.5 1.8-1l14 8.8c.7.5.7 1.5 0 2l-14 8.8c-.8.5-1.8-.1-1.8-1z" />
	</svg>
	Get the Android app
</a>
