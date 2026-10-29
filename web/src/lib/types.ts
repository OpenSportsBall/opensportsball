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
	recordingCount: number;
	status: RecordingStatus;
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
	status: RecordingStatus;
	hasManifest: boolean;
	devices: RecordingDevice[];
}

export interface Game {
	gameId: string;
	createdAt: string;
	recordings: Recording[];
}

export interface ApiErrorBody {
	error: string;
	message: string;
}
