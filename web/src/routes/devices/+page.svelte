<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import { toString as qrToSvg } from 'qrcode';
	import { replaceState } from '$app/navigation';
	import { page } from '$app/state';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import {
		formatCountdown,
		formatDate,
		formatDateTime,
		formatLinkCode,
		formatRelative,
		platformLabel
	} from '#lib/format.ts';
	import { poll } from '#lib/poll.ts';
	import { session } from '#lib/session.svelte.ts';
	import type { Device, LinkCode } from '#lib/types.ts';

	const LINK_POLL_MS = 3_000;

	let devices = $state<Device[] | null>(null);
	let error = $state<unknown>(null);
	let confirming = $state<string | null>(null);
	let unlinking = $state<string | null>(null);

	// Link flow
	let linkOpen = $state(false);
	let creating = $state(false);
	let link = $state<LinkCode | null>(null);
	let qrSvg = $state('');
	let linkError = $state<unknown>(null);
	let linked = $state<Device | null>(null);
	let now = $state(Date.now());
	/** deviceId -> linkedAt before the code was shown; a new or re-linked phone differs. */
	let baseline = new Map<string, string>();
	let stopLinkPoll = () => {};
	let ticker: ReturnType<typeof setInterval> | undefined;

	const msLeft = $derived(link ? new Date(link.expiresAt).getTime() - now : 0);
	const expired = $derived(link !== null && msLeft <= 0);

	async function loadDevices(): Promise<Device[] | null> {
		try {
			const list = await session.api.listDevices();
			devices = [...list].sort((a, b) => b.linkedAt.localeCompare(a.linkedAt));
			error = null;
			return list;
		} catch (e) {
			error = e;
			return null;
		}
	}

	onMount(async () => {
		if (!(await session.requireSignIn())) return;
		// ?link=1 (from the Games page's "Link a phone") opens the link panel straight away.
		// Drop it from the URL so a reload doesn't mint another code.
		if (page.url.searchParams.has('link')) {
			const url = new URL(page.url.href);
			url.searchParams.delete('link');
			replaceState(url, {});
			await startLink();
		} else {
			await loadDevices();
		}
	});

	function stopLinking() {
		stopLinkPoll();
		stopLinkPoll = () => {};
		clearInterval(ticker);
		ticker = undefined;
	}

	onDestroy(stopLinking);

	async function startLink() {
		stopLinking();
		linkOpen = true;
		creating = true;
		linkError = null;
		linked = null;
		link = null;
		qrSvg = '';
		try {
			const current = (await loadDevices()) ?? devices ?? [];
			baseline = new Map(current.map((d) => [d.deviceId, d.linkedAt]));
			const code = await session.api.createLinkCode();
			qrSvg = await qrToSvg(code.linkUri, {
				type: 'svg',
				margin: 2,
				errorCorrectionLevel: 'M',
				color: { dark: '#000000', light: '#ffffff' }
			});
			link = code;
			now = Date.now();
			ticker = setInterval(() => {
				now = Date.now();
				if (expired) stopLinking();
			}, 1000);
			stopLinkPoll = poll(checkForNewDevice, LINK_POLL_MS);
		} catch (e) {
			linkError = e;
		} finally {
			creating = false;
		}
	}

	async function checkForNewDevice(): Promise<boolean> {
		if (!link || expired) return false;
		const list = await loadDevices();
		const found = list?.find((d) => baseline.get(d.deviceId) !== d.linkedAt);
		if (found) {
			linked = found;
			stopLinking();
			return false;
		}
		return true;
	}

	function closeLink() {
		stopLinking();
		linkOpen = false;
		link = null;
		linked = null;
		linkError = null;
	}

	async function unlink(d: Device) {
		unlinking = d.deviceId;
		try {
			await session.api.unlinkDevice(d.deviceId);
			devices = devices?.filter((x) => x.deviceId !== d.deviceId) ?? null;
			confirming = null;
			error = null;
		} catch (e) {
			error = e;
		} finally {
			unlinking = null;
		}
	}
</script>

<svelte:head><title>Devices · OpenSportsBall</title></svelte:head>

<div class="page-head">
	<h1>Devices</h1>
	{#if !linkOpen}
		<button class="btn btn-primary" onclick={startLink}>Link a phone</button>
	{/if}
</div>

{#if linkOpen}
	<section class="card link-panel" aria-labelledby="link-title">
		<div class="link-head">
			<h2 id="link-title">Link a phone</h2>
			<button class="btn btn-small" onclick={closeLink}>{linked ? 'Done' : 'Cancel'}</button>
		</div>

		{#if linkError}
			<ErrorBanner error={linkError} retry={startLink} />
		{:else if creating}
			<p class="muted">Getting a code…</p>
		{:else if linked}
			<div class="success" role="status">
				<svg viewBox="0 0 24 24" width="40" height="40" aria-hidden="true">
					<circle cx="12" cy="12" r="11" fill="var(--ok)" />
					<path d="M7 12.5l3.2 3.2L17 9" fill="none" stroke="var(--surface)" stroke-width="2.4" />
				</svg>
				<div>
					<strong>{linked.model} is linked.</strong>
					<div class="muted small">It will upload recordings to this account on Wi-Fi.</div>
				</div>
			</div>
			<button class="btn" onclick={startLink}>Link another phone</button>
		{:else if link}
			<p>
				On the phone, open the OpenSportsBall app and scan this code. Or type the code in the app.
			</p>
			<div class="qr" class:faded={expired}>
				<!-- qrcode's SVG output; generated locally from the server's linkUri -->
				{@html qrSvg}
			</div>
			<p class="code mono" aria-label="Link code">{formatLinkCode(link.code)}</p>
			{#if expired}
				<p class="expired" role="status">This code expired.</p>
				<button class="btn btn-primary" onclick={startLink}>Get a new code</button>
			{:else}
				<p class="muted small waiting" aria-live="polite">
					<span class="dot" aria-hidden="true"></span>
					Waiting for the phone… Code expires in
					<span class="mono">{formatCountdown(msLeft)}</span>
				</p>
			{/if}
		{/if}
	</section>
{/if}

{#if error}<ErrorBanner {error} retry={() => void loadDevices()} />{/if}

{#if devices === null && !error}
	<p class="muted">Loading devices…</p>
{:else if devices && devices.length === 0 && !linkOpen}
	<div class="card empty">
		<h2>No phones linked</h2>
		<p class="muted">Link each phone you record with. You need two: a main camera and a second camera.</p>
		<button class="btn btn-primary" onclick={startLink}>Link a phone</button>
	</div>
{:else if devices && devices.length > 0}
	<ul class="devices">
		{#each devices as d (d.deviceId)}
			<li class="card device">
				<div class="info">
					<strong>{d.model}</strong>
					<span class="muted small">{platformLabel(d.platform)}</span>
					<dl class="small">
						<div>
							<dt>Linked</dt>
							<dd title={formatDateTime(d.linkedAt)}>{formatDate(d.linkedAt)}</dd>
						</div>
						<div>
							<dt>Last seen</dt>
							<dd title={d.lastSeenAt ? formatDateTime(d.lastSeenAt) : undefined}>{formatRelative(d.lastSeenAt)}</dd>
						</div>
					</dl>
				</div>
				<div class="actions">
					{#if confirming === d.deviceId}
						<p class="small confirm">Unlink {d.model}? It stops uploading until you link it again.</p>
						<div class="confirm-buttons">
							<button class="btn btn-small" onclick={() => (confirming = null)} disabled={unlinking === d.deviceId}>
								Cancel
							</button>
							<button
								class="btn btn-small btn-danger-solid"
								onclick={() => unlink(d)}
								disabled={unlinking === d.deviceId}
							>
								{unlinking === d.deviceId ? 'Unlinking…' : 'Unlink'}
							</button>
						</div>
					{:else}
						<button class="btn btn-small btn-danger" onclick={() => (confirming = d.deviceId)}>Unlink</button>
					{/if}
				</div>
			</li>
		{/each}
	</ul>
{/if}

<style>
	.link-panel {
		margin-bottom: 1.25rem;
		text-align: center;
	}
	.link-head {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 0.75rem;
		margin-bottom: 0.75rem;
		text-align: left;
	}
	.link-head h2 {
		margin: 0;
	}
	.qr {
		width: min(100%, 320px);
		margin: 0.5rem auto;
		background: #ffffff;
		border-radius: 12px;
		padding: 6px;
		border: 1px solid var(--border);
	}
	.qr :global(svg) {
		display: block;
		width: 100%;
		height: auto;
	}
	.qr.faded {
		opacity: 0.25;
	}
	.code {
		font-size: clamp(1.8rem, 9vw, 2.4rem);
		font-weight: 700;
		letter-spacing: 0.12em;
		margin: 0.5rem 0;
	}
	.waiting {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		flex-wrap: wrap;
		justify-content: center;
	}
	.dot {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--accent);
		animation: pulse 1.2s ease-in-out infinite;
	}
	@keyframes pulse {
		50% {
			opacity: 0.25;
		}
	}
	@media (prefers-reduced-motion: reduce) {
		.dot {
			animation: none;
		}
	}
	.expired {
		color: var(--danger);
		font-weight: 600;
	}
	.success {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		text-align: left;
		justify-content: center;
		margin: 1rem 0;
	}
	.devices {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 0.6rem;
	}
	.device {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		align-items: center;
		gap: 0.75rem;
	}
	.info {
		display: flex;
		flex-wrap: wrap;
		column-gap: 0.5rem;
		align-items: baseline;
		min-width: 0;
	}
	dl {
		flex-basis: 100%;
		display: flex;
		flex-wrap: wrap;
		gap: 0.25rem 1.25rem;
		margin: 0.25rem 0 0;
	}
	dt {
		display: inline;
		color: var(--text-muted);
	}
	dt::after {
		content: ':';
	}
	dd {
		display: inline;
		margin: 0 0 0 0.25rem;
	}
	.actions {
		margin-left: auto;
		text-align: right;
	}
	.confirm {
		margin: 0 0 0.4rem;
		max-width: 22rem;
	}
	.confirm-buttons {
		display: flex;
		gap: 0.5rem;
		justify-content: flex-end;
	}
</style>
