<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import { session } from '#lib/session.svelte.ts';

	// The app links here (Settings → Account) so people can delete
	// their account from the phone too.
	let ready = $state(false);
	let confirming = $state(false);
	let typed = $state('');
	let deleting = $state(false);
	let error = $state<unknown>(null);

	const CONFIRM_WORD = 'DELETE';

	onMount(async () => {
		ready = await session.requireSignIn();
	});

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

	<section class="card stack danger-zone">
		<h2>Delete account</h2>
		<p>
			This deletes your account for good: every game and its footage, your linked phones (they stop uploading),
			upload permissions you gave other phones, and your sign-in. It can't be undone.
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
	.buttons {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}
</style>
