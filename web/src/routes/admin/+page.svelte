<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { ApiError } from '#lib/api.ts';
	import ErrorBanner from '#lib/components/ErrorBanner.svelte';
	import { formatBytes, formatDate, formatRelative, platformLabel } from '#lib/format.ts';
	import { session } from '#lib/session.svelte.ts';
	import type { AdminAccount, AdminReport } from '#lib/types.ts';

	/** Footage under accounts/ expires this long after upload
	 *  (infra/lib/stack.ts FOOTAGE_RETENTION_DAYS). */
	const RETENTION_DAYS = 180;
	/** S3 Standard, us-east-1, first 50 TB: a rough monthly figure only. */
	const USD_PER_GB_MONTH = 0.023;

	let report = $state<AdminReport | null>(null);
	let error = $state<unknown>(null);
	let loading = $state(false);
	let query = $state('');
	let sortKey = $state<SortKey>('storage');
	let sortDesc = $state(true);
	let open = $state<string | null>(null);
	let copied = $state<string | null>(null);

	type SortKey = 'email' | 'status' | 'devices' | 'games' | 'recordings' | 'storage' | 'lastUpload' | 'created';

	const forbidden = $derived(error instanceof ApiError && error.status === 403);

	async function load() {
		loading = true;
		try {
			report = await session.api.adminAccounts();
			error = null;
		} catch (e) {
			error = e;
		} finally {
			loading = false;
		}
	}

	onMount(async () => {
		if (await session.requireSignIn()) await load();
	});

	const sortValue: Record<SortKey, (a: AdminAccount) => string | number> = {
		email: (a) => (a.email ?? '~' + a.accountId).toLowerCase(),
		status: (a) => a.status,
		devices: (a) => a.devices.length,
		games: (a) => a.games,
		recordings: (a) => a.recordings.total,
		storage: (a) => a.storageBytes,
		lastUpload: (a) => a.lastUploadAt ?? '',
		created: (a) => a.createdAt ?? ''
	};

	const rows = $derived.by(() => {
		if (!report) return [];
		const q = query.trim().toLowerCase();
		const list = q
			? report.accounts.filter((a) => (a.email ?? '').toLowerCase().includes(q) || a.accountId.toLowerCase().includes(q))
			: [...report.accounts];
		const f = sortValue[sortKey];
		list.sort((a, b) => {
			const x = f(a);
			const y = f(b);
			const c = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y));
			return sortDesc ? -c : c;
		});
		return list;
	});

	const maxStorage = $derived(Math.max(1, ...(report?.accounts.map((a) => a.storageBytes) ?? [])));

	function sortBy(key: SortKey) {
		if (sortKey === key) sortDesc = !sortDesc;
		else {
			sortKey = key;
			sortDesc = key !== 'email' && key !== 'status';
		}
	}

	const ariaSort = (key: SortKey) => (sortKey === key ? (sortDesc ? 'descending' : 'ascending') : 'none');

	function monthlyCost(bytes: number) {
		const usd = (bytes / 1e9) * USD_PER_GB_MONTH;
		return usd < 0.01 && usd > 0 ? '< $0.01' : `$${usd.toFixed(2)}`;
	}

	function expiresOn(oldest: string | null) {
		if (!oldest) return null;
		return new Date(new Date(oldest).getTime() + RETENTION_DAYS * 86400_000).toISOString();
	}

	const STATUS_TEXT: Record<AdminAccount['status'], string> = {
		active: 'Active',
		disabled: 'Disabled',
		unconfirmed: 'Unconfirmed',
		deleted: 'Deleted',
		no_sign_in: 'No sign-in'
	};

	async function copy(text: string) {
		try {
			await navigator.clipboard.writeText(text);
			copied = text;
			setTimeout(() => (copied = copied === text ? null : copied), 1500);
		} catch {
			/* clipboard blocked: the id is still selectable */
		}
	}
</script>

<svelte:head><title>Admin · OpenSportsBall</title></svelte:head>

<div class="page-head">
	<h1>Admin</h1>
	{#if report}
		<div class="refresh">
			<span class="muted small">As of {formatRelative(report.generatedAt)}</span>
			<button class="btn btn-small" onclick={() => void load()} disabled={loading}>
				{loading ? 'Refreshing…' : 'Refresh'}
			</button>
		</div>
	{/if}
</div>

{#if forbidden}
	<div class="card stack">
		<h2>Admins only</h2>
		<p>This account isn't in the admins group.</p>
		<p class="muted small">
			If you were just added, sign out and back in: the group is read from your sign-in when it starts.
		</p>
	</div>
{:else if error}
	<ErrorBanner {error} retry={() => void load()} />
{/if}

{#if !report && !error}
	<p class="muted">Loading accounts…</p>
{:else if report}
	<section class="tiles" aria-label="Totals">
		<div class="card tile">
			<div class="label">Accounts</div>
			<div class="value">{report.totals.accounts}</div>
			<div class="muted small">{report.totals.deletedAccounts} deleted</div>
		</div>
		<div class="card tile">
			<div class="label">Phones</div>
			<div class="value">{report.totals.devices}</div>
			<div class="muted small">linked</div>
		</div>
		<div class="card tile">
			<div class="label">Recordings</div>
			<div class="value">{report.totals.recordings}</div>
			<div class="muted small">in {report.totals.games} games</div>
		</div>
		<div class="card tile">
			<div class="label">Storage</div>
			<div class="value">{formatBytes(report.totals.storageBytes)}</div>
			<div class="muted small">≈ {monthlyCost(report.totals.storageBytes)}/month · {report.totals.objectCount} files</div>
		</div>
	</section>

	<div class="toolbar">
		<label class="search">
			<span class="visually-hidden">Filter accounts</span>
			<input type="search" placeholder="Filter by email or account id" bind:value={query} autocomplete="off" spellcheck="false" />
		</label>
		<span class="muted small">{rows.length} of {report.accounts.length} accounts</span>
	</div>

	<div class="card table-wrap">
		<table>
			<thead>
				<tr>
					{#snippet th(key: SortKey, label: string, num = false)}
						<th aria-sort={ariaSort(key)} class:num>
							<button onclick={() => sortBy(key)}>
								{label}<span class="arrow" aria-hidden="true">{sortKey === key ? (sortDesc ? '↓' : '↑') : ''}</span>
							</button>
						</th>
					{/snippet}
					{@render th('email', 'Account')}
					{@render th('status', 'Status')}
					{@render th('devices', 'Phones', true)}
					{@render th('games', 'Games', true)}
					{@render th('recordings', 'Recordings', true)}
					{@render th('storage', 'Storage', true)}
					{@render th('lastUpload', 'Last upload')}
					{@render th('created', 'Joined')}
				</tr>
			</thead>
			<tbody>
				{#each rows as a (a.accountId)}
					{@const expanded = open === a.accountId}
					<tr class:dim={a.status === 'deleted'} class:expanded>
						<td class="account">
							<button
								class="expander"
								aria-expanded={expanded}
								onclick={() => (open = expanded ? null : a.accountId)}
								title="Show details"
							>
								<span class="chev" aria-hidden="true">{expanded ? '▾' : '▸'}</span>
								<span class="email-cell">{a.email ?? a.accountId}</span>
							</button>
						</td>
						<td><span class="pill pill-{a.status}">{STATUS_TEXT[a.status]}</span></td>
						<td class="num">{a.devices.length}</td>
						<td class="num">{a.games}</td>
						<td class="num">
							{a.recordings.total}
							{#if a.recordings.total > a.recordings.ready}
								<div class="muted tiny">{a.recordings.total - a.recordings.ready} unfinished</div>
							{/if}
						</td>
						<td class="num storage">
							{formatBytes(a.storageBytes)}
							<div class="bar" aria-hidden="true"><span style="width: {(a.storageBytes / maxStorage) * 100}%"></span></div>
						</td>
						<td title={a.lastUploadAt ?? ''}>{a.lastUploadAt ? formatRelative(a.lastUploadAt) : '—'}</td>
						<td>{formatDate(a.createdAt)}</td>
					</tr>
					{#if expanded}
						<tr class="details">
							<td colspan="8">
								<dl>
									<div>
										<dt>Account id</dt>
										<dd>
											<code class="mono">{a.accountId}</code>
											<button class="btn btn-small" onclick={() => void copy(a.accountId)}>
												{copied === a.accountId ? 'Copied' : 'Copy'}
											</button>
										</dd>
									</div>
									<div>
										<dt>Recordings</dt>
										<dd>
											{a.recordings.ready} ready · {a.recordings.uploading} uploading · {a.recordings.waiting_for_manifest} waiting for
											manifest
										</dd>
									</div>
									<div>
										<dt>Storage</dt>
										<dd>
											{formatBytes(a.storageBytes)} in {a.objectCount} files · ≈ {monthlyCost(a.storageBytes)}/month
										</dd>
									</div>
									<div>
										<dt>Oldest footage</dt>
										<dd>
											{#if a.oldestObjectAt}
												{formatDate(a.oldestObjectAt)} (expires {formatDate(expiresOn(a.oldestObjectAt))})
											{:else}
												—
											{/if}
										</dd>
									</div>
									<div>
										<dt>Phones</dt>
										<dd>
											{#if a.devices.length === 0}
												None linked
											{:else}
												<ul class="phones">
													{#each a.devices as d (d.deviceId)}
														<li>
															{d.model} <span class="muted">({platformLabel(d.platform)})</span> · linked {formatDate(d.linkedAt)} ·
															seen {formatRelative(d.lastSeenAt)}
														</li>
													{/each}
												</ul>
											{/if}
										</dd>
									</div>
								</dl>
							</td>
						</tr>
					{/if}
				{:else}
					<tr><td colspan="8" class="muted none">No accounts match “{query}”.</td></tr>
				{/each}
			</tbody>
		</table>
	</div>
	<p class="muted small note">
		Storage is everything under each account's folder in the footage bucket; the monthly figure assumes S3 Standard at
		${USD_PER_GB_MONTH}/GB. Deleted accounts appear only while something of theirs is left behind.
	</p>
{/if}

<style>
	.refresh {
		display: flex;
		align-items: center;
		gap: 0.6rem;
	}
	.tiles {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
		gap: 0.6rem;
		margin-bottom: 1rem;
	}
	.tile .label {
		color: var(--text-muted);
		font-size: 0.85rem;
		font-weight: 700;
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}
	.tile .value {
		font-family: var(--font-display);
		font-size: 1.75rem;
		font-weight: 700;
		line-height: 1.2;
		font-variant-numeric: tabular-nums;
	}
	.toolbar {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 0.6rem;
		margin-bottom: 0.6rem;
	}
	.search {
		flex: 1 1 260px;
		max-width: 380px;
	}
	.search input {
		width: 100%;
		min-height: 40px;
		padding: 0.4rem 0.75rem;
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-sm);
		background: var(--surface);
		color: var(--text);
		font: inherit;
	}
	.table-wrap {
		padding: 0;
		overflow-x: auto;
	}
	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.9rem;
		font-variant-numeric: tabular-nums;
	}
	th,
	td {
		padding: 0.55rem 0.7rem;
		text-align: left;
		vertical-align: top;
		white-space: nowrap;
		border-bottom: 1px solid var(--border);
	}
	tbody tr:last-child td {
		border-bottom: none;
	}
	th {
		background: var(--surface-2);
		font-size: 0.8rem;
		padding-top: 0.4rem;
		padding-bottom: 0.4rem;
	}
	th button {
		all: unset;
		cursor: pointer;
		font-weight: 700;
		color: var(--text-muted);
	}
	th[aria-sort='ascending'] button,
	th[aria-sort='descending'] button {
		color: var(--text);
	}
	th button:focus-visible {
		outline: 3px solid var(--focus);
		outline-offset: 2px;
	}
	.arrow {
		display: inline-block;
		width: 1em;
		text-align: center;
	}
	.num {
		text-align: right;
	}
	.account {
		max-width: 260px;
	}
	.expander {
		all: unset;
		cursor: pointer;
		display: flex;
		align-items: baseline;
		gap: 0.35rem;
		max-width: 100%;
		font-weight: 700;
	}
	.expander:focus-visible {
		outline: 3px solid var(--focus);
		outline-offset: 2px;
	}
	.chev {
		color: var(--text-muted);
		width: 0.8em;
		flex-shrink: 0;
	}
	.email-cell {
		overflow: hidden;
		text-overflow: ellipsis;
	}
	tr.dim td {
		color: var(--text-muted);
	}
	tr.expanded td {
		border-bottom: none;
		background: var(--surface-2);
	}
	tr.details td {
		background: var(--surface-2);
		white-space: normal;
		padding: 0.25rem 0.7rem 0.9rem 2rem;
	}
	.tiny {
		font-size: 0.75rem;
	}
	.storage {
		min-width: 110px;
	}
	.bar {
		height: 4px;
		margin-top: 4px;
		background: var(--track);
		border-radius: 2px;
		overflow: hidden;
	}
	.bar span {
		display: block;
		height: 100%;
		margin-left: auto;
		background: var(--accent);
	}
	.pill {
		display: inline-block;
		padding: 0.05rem 0.5rem;
		border-radius: 999px;
		font-size: 0.78rem;
		font-weight: 700;
	}
	.pill-active {
		background: var(--ok-bg);
		color: var(--ok);
	}
	.pill-unconfirmed {
		background: var(--info-bg);
		color: var(--info);
	}
	.pill-disabled,
	.pill-no_sign_in {
		background: var(--warn-bg);
		color: var(--warn);
	}
	.pill-deleted {
		background: var(--danger-bg);
		color: var(--danger);
	}
	dl {
		display: grid;
		gap: 0.4rem;
		margin: 0;
	}
	dl > div {
		display: grid;
		grid-template-columns: 8.5rem 1fr;
		gap: 0.75rem;
		align-items: baseline;
	}
	dt {
		color: var(--text-muted);
		font-weight: 700;
	}
	dd {
		margin: 0;
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		gap: 0.5rem;
	}
	dd code {
		word-break: break-all;
	}
	.phones {
		margin: 0;
		padding-left: 1.1rem;
	}
	.none {
		text-align: center;
		padding: 1.5rem;
	}
	.note {
		margin-top: 0.75rem;
	}
	@media (max-width: 560px) {
		dl > div {
			grid-template-columns: 1fr;
			gap: 0.1rem;
		}
		tr.details td {
			padding-left: 0.7rem;
		}
	}
</style>
