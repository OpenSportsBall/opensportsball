// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Mock mode only (lib/mock.ts): the made-up game the checks are shown for,
 * in the engine's formats. The same scene the stub engine writes
 * (infra/stub-engine/scene.mjs): a drawn pitch whose first "fit" is off at
 * the right-hand end. Pictures are data URLs.
 */
import type { Panorama, PitchAnswer, PitchQuestion } from './types';

const WIDTH = 2000;
const HEIGHT = 600;
const PANORAMA: Panorama = { image: 'background.svg', degPerPx: 0.1, yawRange: [-100, 100], pitchRange: [-20, 40] };

type Px = [number, number];
const toDeg = ([x, y]: Px) => ({
	yaw: Math.round((PANORAMA.yawRange[0] + x * PANORAMA.degPerPx) * 1000) / 1000,
	pitch: Math.round((PANORAMA.pitchRange[0] + y * PANORAMA.degPerPx) * 1000) / 1000
});
const toPx = (p: { yaw: number; pitch: number }): Px => [
	(p.yaw - PANORAMA.yawRange[0]) / PANORAMA.degPerPx,
	(p.pitch - PANORAMA.pitchRange[0]) / PANORAMA.degPerPx
];

const TRUE_POINTS: Record<string, Px> = {
	'left corner flag': [150, 520],
	'right corner flag': [1850, 520],
	'far left corner flag': [520, 250],
	'far right corner flag': [1480, 250],
	'halfway near end': [1000, 520],
	'halfway far end': [1000, 250]
};

const MARKINGS = [
	['left corner flag', 'right corner flag'],
	['far left corner flag', 'far right corner flag'],
	['left corner flag', 'far left corner flag'],
	['right corner flag', 'far right corner flag'],
	['halfway near end', 'halfway far end']
];
const linesPx = (pts: Record<string, Px>): Px[][] => MARKINGS.map(([a, b]) => [pts[a], pts[b]]);

const dataUrl = (svg: string) => `data:image/svg+xml,${encodeURIComponent(svg)}`;
const path = (pts: Px[]) => pts.map(([x, y], i) => `${i ? 'L' : 'M'}${x} ${y}`).join(' ');
const stroke = (lines: Px[][], colour: string, width: number) =>
	lines.map((l) => `<path d="${path(l)}" stroke="${colour}" stroke-width="${width}" fill="none" stroke-linecap="round"/>`).join('');

function pitchSvg(fit?: Record<string, Px>): string {
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${WIDTH} ${HEIGHT}" width="${WIDTH}" height="${HEIGHT}">
<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9cc3e6"/><stop offset="1" stop-color="#dbe9f4"/></linearGradient>
<linearGradient id="turf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3f8a45"/><stop offset="1" stop-color="#2f6f37"/></linearGradient></defs>
<rect width="${WIDTH}" height="200" fill="url(#sky)"/>
<rect y="170" width="${WIDTH}" height="40" fill="#3c5a3a"/>
<rect y="200" width="${WIDTH}" height="400" fill="url(#turf)"/>
${stroke(linesPx(TRUE_POINTS), '#f4f4ec', 5)}
<ellipse cx="1000" cy="372" rx="150" ry="52" stroke="#f4f4ec" stroke-width="5" fill="none"/>
${fit ? stroke(linesPx(fit), '#e0261c', 4) : ''}
<text x="24" y="44" font-family="sans-serif" font-size="28" fill="#1d3b5a">Mock data: a drawn pitch, not footage</text>
</svg>`;
}

/** Where the engine has got to with the pitch check. */
export interface MockChecks {
	pitch: { round: number; status: 'pending' | 'approved'; points: Record<string, Px> };
}

export const firstChecks = (): MockChecks => ({
	pitch: {
		round: 1,
		status: 'pending',
		// Right at the left end, off at the right.
		points: {
			...structuredClone(TRUE_POINTS),
			'right corner flag': [1905, 536],
			'far right corner flag': [1552, 228],
			'halfway far end': [1022, 242]
		}
	}
});

export const pendingChecks = (st: MockChecks): 'pitch'[] => (st.pitch.status === 'pending' ? ['pitch'] : []);

/** Applies an answer as the engine would. True when it had to work on it
 *  (and asks that question again). */
export function applyAnswer(st: MockChecks, a: PitchAnswer): boolean {
	if ('approve' in a) {
		st.pitch.status = 'approved';
		return false;
	}
	for (const [name, p] of Object.entries(a.points)) if ('yaw' in p && st.pitch.points[name]) st.pitch.points[name] = toPx(p);
	st.pitch.round++;
	return true;
}

export function pitchQuestion(st: MockChecks): PitchQuestion {
	return {
		round: st.pitch.round,
		status: st.pitch.status,
		background: 'pitch/background.svg',
		backgroundUrl: dataUrl(pitchSvg()),
		overlay: 'pitch/overlay.svg',
		overlayUrl: dataUrl(pitchSvg(st.pitch.points)),
		panorama: PANORAMA,
		lines: linesPx(st.pitch.points).map((l) => l.map((p) => [toDeg(p).yaw, toDeg(p).pitch] as [number, number])),
		points: Object.fromEntries(Object.entries(st.pitch.points).map(([name, p]) => [name, toDeg(p)]))
	};
}
