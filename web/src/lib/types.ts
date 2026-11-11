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
/** The engine's questions. `cameras` is asked only when the phones' views
 *  couldn't be stitched, and then before the other two. */
export type CheckName = 'cameras' | 'pitch' | 'kits';

export interface Job {
	schemaVersion: 1;
	jobId: string;
	gameId: string;
	recordingId: string;
	where: 'cloud' | 'local';
	status: JobStatus;
	/** Up to the checks, or after them; tells the two `queued` states apart. */
	phase: 'prepare' | 'run';
	checks: Partial<Record<CheckName, 'open' | 'answered'>>;
	progress: { stage: string; fraction: number; etaSeconds?: number | null; at?: string } | null;
	error: { code: string; message: string } | null;
	/** The recording became ready again (a second phone) after this started. */
	stale: boolean;
	engineVersion: string | null;
	createdAt: string;
	updatedAt: string;
	finishedAt: string | null;
}

// The engine's own questions and answers (shared/schemas/engine-questions and
// engine-answers), as the API passes them through with a signed `...Url`
// next to every picture. Angles are panorama degrees: yaw right +, pitch down +.

/** The background picture's pixels: x = (yaw - yawRange[0]) / degPerPx,
 *  y = (pitch - pitchRange[0]) / degPerPx. */
export interface Panorama {
	image: string;
	degPerPx: number;
	yawRange: [number, number];
	pitchRange: [number, number];
}

export interface PitchPoint {
	yaw: number;
	pitch: number;
}

export interface PitchQuestion {
	round: number;
	status: 'pending' | 'approved';
	/** The empty pitch; `overlay` is the same with the fitted lines drawn on. */
	background: string;
	backgroundUrl: string | null;
	overlay: string;
	overlayUrl: string | null;
	panorama?: Panorama | null;
	/** Each fitted marking as a polyline of [yaw, pitch]. */
	lines: [number, number][][];
	/** Named keypoints where the fit puts them: what a correction starts from. */
	points: Record<string, PitchPoint>;
	/** False when the pitch has to be marked before it can be approved. */
	approveAllowed?: boolean;
	/** Why the last answer wasn't accepted. */
	problem?: string;
}

export interface KitCrop {
	id: string;
	image: string;
	imageUrl: string | null;
}

export interface KitGroup {
	/** The group's number in answers. */
	component: number;
	people: number;
	perMoment: number;
	/** The engine's guess. A and B are the two sides, in no order. */
	proposed: 'A' | 'B' | 'keeperOrReferee' | 'other';
	crops: KitCrop[];
}

export interface KitsQuestion {
	round: number;
	status: 'pending' | 'answered';
	k: number;
	splitAllowed: boolean;
	problem?: string;
	groups: KitGroup[];
}

/** Asked only when the phones' views couldn't be stitched: which order of
 *  the phones shows the pitch in one piece. */
export interface CamerasQuestion {
	round: number;
	status: 'pending' | 'answered';
	panoramas: { mainLeft: string; mainLeftUrl: string | null; secondaryLeft: string; secondaryLeftUrl: string | null };
	reason?: string;
}

/** GET .../jobs/{jobId}/questions */
export interface JobQuestions {
	status: JobStatus;
	checks: Job['checks'];
	expiresAt: string;
	questions: {
		schemaVersion: 1;
		pending: CheckName[];
		cameras?: CamerasQuestion;
		pitch?: PitchQuestion;
		kits?: KitsQuestion;
	};
}

export type PitchPointAnswer = { yaw: number; pitch: number } | { fromFit: true } | { skipped: true };

export type PitchAnswer =
	| { question: 'pitch'; round: number; approve: true }
	| { question: 'pitch'; round: number; points: Record<string, PitchPointAnswer> };

export interface KitsAnswer {
	question: 'kits';
	round: number;
	/** Per group (its component number), the crops tapped as not belonging. */
	tapped?: Record<string, string[]>;
	/** Sets of groups that are the same kit. */
	merge?: number[][];
	/** A group that holds two kits. */
	split?: number;
	/** Only when the user changed a group's role; otherwise the engine keeps its guess. */
	keeperOrReferee?: number[];
	notKit?: number[];
}

export interface CamerasAnswer {
	question: 'cameras';
	round: number;
	leftPhone: 'main' | 'secondary';
}

export type CheckAnswer = PitchAnswer | KitsAnswer | CamerasAnswer;

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
