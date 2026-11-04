<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { resolve } from '$app/paths';
	import { REPO_URL, SUPPORT_EMAIL } from '#lib/site.ts';
</script>

<svelte:head><title>Support · OpenSportsBall</title></svelte:head>

<article class="prose">
	<h1>Support</h1>
	<p>
		Questions, problems, or ideas? Email <a href="mailto:{SUPPORT_EMAIL}">{SUPPORT_EMAIL}</a>, or open an issue on
		<a href="{REPO_URL}/issues">GitHub</a>.
	</p>

	<h2>Getting started</h2>
	<ol>
		<li>Install OpenSportsBall on two phones.</li>
		<li>
			On each phone, open <strong>Settings</strong>, tap <strong>Link to account</strong> and sign in, or scan the QR code from the
			<a href={resolve('/devices')}>Devices</a> page here.
		</li>
		<li>
			At the game, set both phones up on tripods, pair them, and press record on the main phone.
		</li>
		<li>Back on Wi-Fi, the phones upload by themselves. Follow progress on the <a href={resolve('/games')}>Games</a> page.</li>
	</ol>

	<h2>Common questions</h2>
	<h3>The phones won't pair</h3>
	<p>Turn on Bluetooth on both phones and allow the app to use it. Keep them within a few meters while pairing.</p>
	<h3>Uploads are stuck</h3>
	<p>
		Uploads wait for Wi-Fi unless you turn off <strong>Upload on Wi-Fi only</strong> on the app's Uploads screen, or
		tap <strong>Upload now using mobile data</strong>. Check that <strong>Upload to cloud</strong> is on in Settings.
		Leave the app open, or let it run in the background, until the Games page shows the recording as ready.
	</p>
	<h3>How do I delete my footage or account?</h3>
	<p>
		Delete games on the <a href={resolve('/games')}>Games</a> page, or everything on the
		<a href={resolve('/account')}>Account</a> page. See the <a href={resolve('/privacy')}>privacy policy</a>.
	</p>
</article>

<style>
	.prose {
		max-width: 42rem;
	}
	.prose h2 {
		font-size: 1.15rem;
		margin-top: 1.75rem;
	}
	.prose h3 {
		font-size: 1rem;
		margin: 1.25rem 0 0.25rem;
	}
	.prose li + li {
		margin-top: 0.4rem;
	}
</style>
