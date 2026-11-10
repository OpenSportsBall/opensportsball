<!-- SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<script lang="ts">
	import { resolve } from '$app/paths';
	import { REPO_URL, SUPPORT_EMAIL } from '#lib/site.ts';

	const UPDATED = 'November 10, 2026';
</script>

<svelte:head><title>Privacy policy · OpenSportsBall</title></svelte:head>

<article class="prose">
	<h1>Privacy policy</h1>
	<p class="muted">Last updated {UPDATED}</p>

	<p>
		OpenSportsBall is a free, open-source way to record youth sports games with two phones and turn the footage into
		one game video. This policy covers the OpenSportsBall app for iPhone and Android and this website. The source
		code for both is public at <a href={REPO_URL}>{REPO_URL.replace('https://', '')}</a>, so you can check what is
		described here.
	</p>

	<h2>What we collect</h2>
	<ul>
		<li>
			<strong>Your account:</strong> your email address and a password, held by our sign-in service (Amazon Cognito).
			We never see your password.
		</li>
		<li>
			<strong>Game footage:</strong> the video and audio your phones record, if you choose to upload it. Footage often shows
			players, many of them children, along with coaches and spectators. Audio is used to line up the two phones'
			videos.
		</li>
		<li>
			<strong>Recording details:</strong> when each recording started and stopped, the video settings, and how the
			two phones' clocks line up.
		</li>
		<li>
			<strong>Your phones:</strong> a random ID the app creates, the platform (iOS or Android) and the phone's model
			name, when it was linked, and when it last contacted us.
		</li>
		<li>
			<strong>Service logs:</strong> our servers record requests, including IP addresses, to keep the service running
			and secure.
		</li>
		<li>
			<strong>Results you choose to share</strong> (only if you turn sharing on, in the Mac app): when you process a
			game on your own computer, you check the pitch lines and the kit groups, and you may label the ball or mark
			moments the camera missed. If you agree, the app sends those results to improve OpenSportsBall: the empty-pitch
			panorama and the points you marked, small pictures of people on the pitch grouped by kit, still frames and
			panoramas of the game, and your labels. These are pictures of the game, so they show players, often children,
			and anyone else in view. We record which wording of the agreement you accepted.
		</li>
	</ul>
	<p>
		The app uses Bluetooth only to connect your two phones to each other, not to find your location. It asks for the
		camera to record and to scan QR codes, and for the microphone to record game audio. Recordings stay on your phone
		unless you link it to an account and leave uploading turned on.
	</p>

	<h2>What we don't do</h2>
	<ul>
		<li>No ads, no advertising IDs, no analytics or tracking SDKs.</li>
		<li>We don't sell or share your data with anyone for their own use.</li>
	</ul>

	<h2>How we use it</h2>
	<p>
		Only to run the service: to sign you in, to receive uploads from your phones, to turn your footage into a game
		video, to show you your games, to improve our offering, and to fix problems. Results you choose to share are used
		to train and test OpenSportsBall's models (pitch mapping, team colours, ball finding and following the play), and
		only by the people who build them. We don't publish them or share them outside the project.
	</p>

	<h2>Where it is stored, and who processes it</h2>
	<p>
		Everything is stored with Amazon Web Services in the United States (Oregon), encrypted at rest and sent over
		encrypted connections. AWS processes it on our behalf and may not use it for anything else. Footage is reachable
		only by your account and by phones you link or give permission to upload to a game.
	</p>

	<h2>How long we keep it</h2>
	<ul>
		<li>
			Uploaded footage (video and audio): deleted automatically 180 days after it is uploaded, or sooner if you
			delete it or your account.
		</li>
		<li>
			Games and recording details: until you delete them or your account. When you delete a game or recording we
			keep only its ID and when it was deleted (see below).
		</li>
		<li>
			Results you choose to share: kept apart from your footage until you withdraw them, delete your account, or
			your account goes unused for 3 years (no sign-in, and none of your phones or computers contacting us). They are
			not deleted when you delete the game they came from, and footage expiring after 180 days doesn't remove
			them. A model already trained on them isn't undone.
		</li>
		<li>Service logs: up to 3 months.</li>
		<li>
			Database backups: up to 35 days. After you delete something it can stay in these backups until they expire;
			they are used only to recover from failures.
		</li>
	</ul>

	<h2>Deleting your data</h2>
	<p>
		You can delete a recording or a whole game on the Games page. Its footage and details are removed right away;
		we keep only the game or recording ID and when it was deleted, so that a phone still trying to upload it is
		turned away instead of adding it back. That record goes when you delete your account. To delete everything, go to
		<a href={resolve('/account')}>Account</a> and choose <strong>Delete my account</strong>. The app links to it
		from its account screen. It removes your footage, games, linked phones and sign-in right away. We keep only
		a record of your account ID and when it was deleted, so that a phone still trying to upload is turned away.
		Deleting your account also deletes everything you shared. To withdraw a shared result on its own, go to
		<a href={resolve('/account')}>Account</a>, <strong>Shared to improve OpenSportsBall</strong>: its files are
		deleted right away. Or email us at <a href="mailto:{SUPPORT_EMAIL}">{SUPPORT_EMAIL}</a> and we'll do it for you.
	</p>

	<h2>Children</h2>
	<p>
		Accounts are for parents, coaches and other adults who record games. The service is not meant for children to
		use, and we don't knowingly create accounts for children under 13. Only record players when you are allowed to,
		following your league's and team's rules. If a child has an account, or you want footage of your child
		removed, contact us and we'll delete it.
	</p>

	<h2>Your rights</h2>
	<p>
		Depending on where you live, you may have the right to see, correct, export or delete your data, or object to how
		it is used. Most of this you can do yourself on this site. For anything else, email
		<a href="mailto:{SUPPORT_EMAIL}">{SUPPORT_EMAIL}</a>.
	</p>

	<h2>Changes</h2>
	<p>If we change this policy, we'll update it here and change the date at the top.</p>

	<h2>Contact</h2>
	<p><a href="mailto:{SUPPORT_EMAIL}">{SUPPORT_EMAIL}</a></p>
</article>

<style>
	.prose {
		max-width: 42rem;
	}
	.prose h2 {
		font-size: 1.15rem;
		margin-top: 1.75rem;
	}
	.prose li + li {
		margin-top: 0.4rem;
	}
</style>
