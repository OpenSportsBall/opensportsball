<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import { formatBytes, formatDate } from '#lib/format.ts';
	import { session } from '#lib/session.svelte.ts';
	import type { Contribution } from '#lib/types.ts';

	// The app links here (Settings → Account) so people can delete
	// their account from the phone too.
	let ready = $state(false);
	let confirming = $state(false);
	let typed = $state('');
	let deleting = $state(false);
	let error = $state<unknown>(null);

	const CONFIRM_WORD = 'DELETE';

	// What was shared from the Mac app to improve the models; each can be withdrawn.
	let shared = $state<Contribution[] | null>(null);
	let sharedError = $state<unknown>(null);
	let withdrawing = $state<string | null>(null);
	const KIND_LABELS: Record<string, string> = {
		pitch: 'Pitch check',
		kits: 'Kit check',
		ball: 'Ball labels',
		moments: 'Must-see moments'
	};

	onMount(async () => {
		ready = await session.requireSignIn();
		if (ready) await loadShared();
	});

	async function loadShared() {
		try {
			shared = await session.api.listContributions();
		} catch (e) {
			sharedError = e;
		}
	}

	async function withdraw(c: Contribution) {
		if (!confirm(`Withdraw this ${(KIND_LABELS[c.kind] ?? c.kind).toLowerCase()}? Its files are deleted for good.`)) return;
		withdrawing = c.contributionId;
		sharedError = null;
		try {
			await session.api.withdrawContribution(c.contributionId);
			shared = (shared ?? []).filter((x) => x.contributionId !== c.contributionId);
		} catch (e) {
			sharedError = e;
		} finally {
			withdrawing = null;
		}
	}

	async function deleteAccount() {
		deleting = true;
		error = null;
		try {
			await session.api.deleteAccount();
			await session.signOut();
		} catch (e) {
			error = e;
			deleting = false;
		}
	}
</script>

<svelte:head><title>Account · OpenSportsBall</title></svelte:head>

<div class="page-head"><h1>Account</h1></div>

{#if ready}
	<section class="card stack">
		<h2>Signed in as</h2>
		<p class="email">{session.email ?? 'Unknown email'}</p>
		<button class="btn" onclick={() => session.signOut()}>Sign out</button>
	</section>

	<section class="card stack">
		<h2>Shared to improve OpenSportsBall</h2>
		<p class="muted small">
			Pitch maps, kit groups and labels you chose to share from the Mac app. They are kept apart from your footage and
			aren't deleted with a game; withdraw one here and its files are deleted. See the
			<a href={resolve('/privacy')}>privacy policy</a>.
		</p>
		{#if sharedError}<ErrorBanner error={sharedError} />{/if}
		{#if shared === null && !sharedError}
			<p class="muted">Loading…</p>
		{:else if shared && shared.length === 0}
			<p class="muted">Nothing shared.</p>
		{:else if shared}
			<ul class="shared">
				{#each shared as c (c.contributionId)}
					<li>
						<span>
							<strong>{KIND_LABELS[c.kind] ?? c.kind}</strong>
							<span class="muted small"
								>{formatDate(c.createdAt)} · {c.files} file{c.files === 1 ? '' : 's'} · {formatBytes(c.bytes)}{c.status ===
								'uploading'
									? ' · not finished uploading'
									: ''}</span
							>
						</span>
						<button class="btn" onclick={() => withdraw(c)} disabled={withdrawing === c.contributionId}>
							{withdrawing === c.contributionId ? 'Withdrawing…' : 'Withdraw'}
						</button>
					</li>
				{/each}
			</ul>
		{/if}
	</section>

	<section class="card stack danger-zone">
		<h2>Delete account</h2>
		<p>
			This deletes your account for good: every game and its footage, everything you shared to improve
			OpenSportsBall, your linked phones (they stop uploading), upload permissions you gave other phones, and your
			sign-in. It can't be undone.
		</p>
		<p class="muted small">
			Recordings still on your phones stay on them until you delete them there. See the
			<a href={resolve('/privacy')}>privacy policy</a> for what is kept and for how long.
		</p>
		{#if error}<ErrorBanner {error} />{/if}
		{#if !confirming}
			<button class="btn btn-danger" onclick={() => (confirming = true)}>Delete my account…</button>
		{:else}
			<label class="stack">
				<span>Type <strong>{CONFIRM_WORD}</strong> to confirm.</span>
				<input
					type="text"
					bind:value={typed}
					autocomplete="off"
					autocapitalize="characters"
					spellcheck="false"
					disabled={deleting}
				/>
			</label>
			<div class="buttons">
				<button
					class="btn"
					onclick={() => {
						confirming = false;
						typed = '';
					}}
					disabled={deleting}>Cancel</button
				>
				<button
					class="btn btn-danger-solid"
					onclick={deleteAccount}
					disabled={deleting || typed.trim().toUpperCase() !== CONFIRM_WORD}
				>
					{deleting ? 'Deleting…' : 'Delete account and all footage'}
				</button>
			</div>
		{/if}
	</section>
{/if}

<style>
	section + section {
		margin-top: 1rem;
	}
	h2 {
		font-size: 1.1rem;
		margin: 0;
	}
	.email {
		font-weight: 600;
		overflow-wrap: anywhere;
	}
	.danger-zone {
		border-color: var(--danger);
	}
	input {
		font: inherit;
		padding: 0.5rem 0.75rem;
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-sm);
		background: var(--surface);
		color: var(--text);
		max-width: 16rem;
		display: block;
	}
	.shared {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.shared li {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 0.75rem;
		padding: 0.5rem 0;
		border-top: 1px solid var(--border);
	}
	.shared li > span {
		display: flex;
		flex-direction: column;
	}
	.buttons {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}
</style>
