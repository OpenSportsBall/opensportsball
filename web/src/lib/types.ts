// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

// Shapes from docs/API.md (v1). Times are ISO-8601 UTC strings.

export interface SiteConfig {
	/** API Gateway base URL, or "mock" for the in-browser mock API. */
	apiUrl: string;
	region: string;
	userPoolId: string;
	userPoolClientId: string;
	cognitoDomain: string;
}

export type RecordingStatus = 'waiting_for_manifest' | 'uploading' | 'ready';
export type Platform = 'ios' | 'android';
export type Role = 'main' | 'secondary';

export interface Me {
	accountId: string;
	email: string;
	/** In the Cognito `admins` group: may open /admin. */
	admin?: boolean;
	/** An admin has switched cloud processing on for this account. */
	cloudProcessing?: boolean;
}

// --- Processing jobs (shared/schemas/job.schema.json and the others) --------

export type JobStatus =
	| 'queued'
	| 'preparing'
	| 'needs_answers'
	| 'refitting'
	| 'running'
	| 'done'
	| 'failed'
	| 'cancelled';
export type CheckName = 'pitch' | 'kits';

export interface Job {
	schemaVersion: 1;
	jobId: string;
	gameId: string;
	recordingId: string;
	where: 'cloud' | 'local';
	status: JobStatus;
	/** Up to the checks, or after them; tells the two `queued` states apart. */
	phase: 'prepare' | 'run';
	checks: Record<CheckName, 'open' | 'answered'>;
	progress: { stage: string; fraction: number; etaSeconds?: number | null; at?: string } | null;
	error: { code: string; message: string } | null;
	/** The recording became ready again (a second phone) after this started. */
	stale: boolean;
	engineVersion: string | null;
	createdAt: string;
	updatedAt: string;
	finishedAt: string | null;
}

/** A point in an image's pixels, origin top left. */
export type Point = [number, number];

export interface PitchKeypoint {
	id: string;
	label: string;
	x: number;
	y: number;
}

export interface PitchQuestion {
	round: number;
	text: string;
	image: string;
	/** Signed link to `image`; null if the engine named a file it may not. */
	imageUrl: string | null;
	width: number;
	height: number;
	lines: Point[][];
	keypoints: PitchKeypoint[];
	paint?: { text: string; choice: string; options: { id: string; label: string; image?: string; imageUrl?: string | null }[] };
}

export interface KitPerson {
	id: string;
	image: string;
	imageUrl: string | null;
}

export interface KitsQuestion {
	round: number;
	text: string;
	canSplit: boolean;
	groups: { id: string; people: KitPerson[] }[];
}

/** GET .../jobs/{jobId}/questions */
export interface JobQuestions {
	status: JobStatus;
	checks: Job['checks'];
	expiresAt: string;
	questions: { schemaVersion: 1; jobId: string; engineVersion?: string; pitch: PitchQuestion; kits: KitsQuestion };
}

export type PitchAnswer =
	| { check: 'pitch'; round: number; approved: true; paint?: string }
	| {
			check: 'pitch';
			round: number;
			approved: false;
			keypoints: ({ id: string; x: number; y: number } | { id: string; skipped: true })[];
			paint?: string;
	  };

export type KitStructure = { kind: 'ok' } | { kind: 'merge'; groups: string[] } | { kind: 'split'; group: string };

export interface KitsAnswer {
	check: 'kits';
	round: number;
	wrong: { groupId: string; personId: string }[];
	structure: KitStructure;
}

/** POST .../jobs/{jobId}/downloads */
export interface JobVideo {
	expiresAt: string;
	video: { url: string; bytes: number | null; fileName: string };
}

/** GET /admin/accounts, one row per account. */
export interface AdminAccount {
	accountId: string;
	email: string | null;
	/** `deleted`: closed, but something was left behind. `no_sign_in`: data
	 *  for an id with no Cognito user. */
	status: 'active' | 'disabled' | 'unconfirmed' | 'deleted' | 'no_sign_in';
	createdAt: string | null;
	devices: Device[];
	games: number;
	recordings: Record<RecordingStatus, number> & { total: number };
	/** May start cloud processing. */
	cloudProcessing: boolean;
	storageBytes: number;
	objectCount: number;
	lastUploadAt: string | null;
	oldestObjectAt: string | null;
}

/** GET /admin/accounts/{accountId}/games: one recording and its footage. */
export interface AdminRecording {
	recordingId: string;
	createdAt: string | null;
	recordedAt: string | null;
	/** Null when the bucket has footage the table has no record of. */
	status: RecordingStatus | null;
	hasManifest: boolean;
	storageBytes: number;
	objectCount: number;
	lastUploadAt: string | null;
}

export interface AdminGame {
	gameId: string;
	createdAt: string | null;
	recordedAt: string | null;
	/** False when the bucket has footage for a game the table doesn't know. */
	inTable: boolean;
	storageBytes: number;
	objectCount: number;
	recordings: AdminRecording[];
}

export interface AdminAccountGames {
	accountId: string;
	email: string | null;
	games: AdminGame[];
}

export interface AdminReport {
	generatedAt: string;
	totals: {
		accounts: number;
		deletedAccounts: number;
		devices: number;
		games: number;
		recordings: number;
		storageBytes: number;
		objectCount: number;
	};
	accounts: AdminAccount[];
}

export interface LinkCode {
	code: string;
	expiresAt: string;
	linkUri: string;
}

/** POST /games/{gameId}/grant-tickets: upload permission for a phone that
 *  recorded the game without a grant from Main. */
export interface GameTicket {
	ticket: string;
	apiUrl: string;
	accountId: string;
	gameId: string;
	expiresAt: string;
	appUri: string;
}

/** POST /grants/lookup: a website ticket's details for the /grant page;
 *  `used` once a phone has redeemed it. */
export interface GrantLookup extends GameTicket {
	used: boolean;
}

/** Something the user shared to improve the models (the Mac app uploads them). */
export interface Contribution {
	contributionId: string;
	gameId: string;
	recordingId: string;
	kind: 'pitch' | 'kits' | 'ball' | 'moments' | string;
	name: string;
	engineVersion: string;
	consentVersion: string;
	status: 'uploading' | 'complete';
	files: number;
	bytes: number;
	createdAt: string;
	completedAt: string | null;
}

export interface Device {
	deviceId: string;
	platform: Platform | string;
	model: string;
	linkedAt: string;
	lastSeenAt: string | null;
}

export interface GameSummary {
	gameId: string;
	createdAt: string;
	/** When recording started; null until a phone has listed its segments. */
	recordedAt: string | null;
	recordingCount: number;
	/** Least-finished status of its recordings; null when it has none. */
	status: RecordingStatus | null;
}

export interface RecordingDevice {
	deviceId: string;
	role: Role | null;
	model: string | null;
	expectedSegments: number | null;
	uploadedSegments: number;
	expectedBytes: number | null;
	uploadedBytes: number;
}

export interface Recording {
	recordingId: string;
	createdAt: string;
	recordedAt: string | null;
	status: RecordingStatus;
	hasManifest: boolean;
	devices: RecordingDevice[];
	/** The newest processing job; null when it was never processed. */
	job: Job | null;
}

export interface Game {
	gameId: string;
	createdAt: string;
	recordedAt: string | null;
	recordings: Recording[];
}

export interface ApiErrorBody {
	error: string;
	message: string;
}
