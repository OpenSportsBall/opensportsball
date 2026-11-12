// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Mock mode only (lib/mock.ts): the made-up game the checks are shown for,
 * in the engine's formats. The same scene the stub engine writes
 * (infra/stub-engine/scene.mjs): a drawn pitch whose first "fit" is off at
 * the right-hand end, and kit groups, one of them two kits mixed together.
 * Pictures are data URLs.
 */
import type { KitGroup, KitsAnswer, KitsQuestion, Panorama, PitchAnswer, PitchQuestion } from './types';

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

type Kit = 'blue' | 'red' | 'green' | 'orange' | 'yellow' | 'grey';
const KITS: Record<Kit, [string, string]> = {
	blue: ['#1f5fbf', '#1f5fbf'],
	red: ['#c62828', '#c62828'],
	green: ['#1b8a3a', '#f4f4ec'],
	orange: ['#ef7d1a', '#ef7d1a'],
	yellow: ['#f2c61f', '#222222'],
	grey: ['#8a8f98', '#8a8f98']
};

function personSvg(kit: Kit, n: number): string {
	const [shirt, trim] = KITS[kit];
	const lean = ((n * 37) % 9) - 4;
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 144" width="96" height="144">
<rect width="96" height="144" fill="#2f6f37"/>
<g transform="rotate(${lean} 48 80)">
<circle cx="48" cy="30" r="12" fill="#e2b48c"/>
<rect x="30" y="44" width="36" height="46" rx="6" fill="${shirt}"/>
<rect x="30" y="60" width="36" height="8" fill="${trim}"/>
<rect x="33" y="90" width="12" height="14" fill="#1c1c1c"/><rect x="51" y="90" width="12" height="14" fill="#1c1c1c"/>
<rect x="35" y="104" width="8" height="26" fill="#e2b48c"/><rect x="53" y="104" width="8" height="26" fill="#e2b48c"/>
</g></svg>`;
}

const PEOPLE = 12;
interface MockGroup {
	kits: Kit[];
	people: number;
	perMoment: number;
	proposed: KitGroup['proposed'];
}
const all = (kit: Kit): Kit[] => Array.from({ length: PEOPLE }, () => kit);

/** Where the engine has got to with the two checks. */
export interface MockChecks {
	pitch: { round: number; status: 'pending' | 'approved'; points: Record<string, Px> };
	kits: { round: number; status: 'pending' | 'answered'; groups: MockGroup[]; splitAllowed: boolean };
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
	},
	kits: {
		round: 1,
		status: 'pending',
		splitAllowed: true,
		// Blue with one red player in it, red, one group that is two kits, the
		// keepers and referee, and people who aren't players.
		groups: [
			{ kits: all('blue').map((k, i) => (i === 7 ? 'red' : k)), people: 412, perMoment: 10.6, proposed: 'A' },
			{ kits: all('red'), people: 388, perMoment: 9.8, proposed: 'B' },
			{ kits: all('green').map((k, i) => (i % 2 ? 'orange' : k)), people: 97, perMoment: 2.4, proposed: 'other' },
			{ kits: all('yellow'), people: 61, perMoment: 1.6, proposed: 'keeperOrReferee' },
			{ kits: all('grey'), people: 33, perMoment: 0.7, proposed: 'other' }
		]
	}
});

export const pendingChecks = (st: MockChecks) => (['pitch', 'kits'] as const).filter((n) => st[n].status === 'pending');

/** Applies an answer as the engine would. True when it had to work on it
 *  (and asks that question again). */
export function applyAnswer(st: MockChecks, a: PitchAnswer | KitsAnswer): boolean {
	if (a.question === 'pitch') {
		if ('approve' in a) {
			st.pitch.status = 'approved';
			return false;
		}
		for (const [name, p] of Object.entries(a.points)) if ('yaw' in p && st.pitch.points[name]) st.pitch.points[name] = toPx(p);
		st.pitch.round++;
		return true;
	}
	if (a.split != null) {
		st.kits.groups = st.kits.groups.flatMap((g, c) => {
			const kinds = [...new Set(g.kits)];
			if (c !== a.split || kinds.length < 2) return [g];
			return kinds.slice(0, 2).map((kind) => ({ kits: all(kind), people: Math.round(g.people / 2), perMoment: g.perMoment / 2, proposed: 'other' as const }));
		});
		st.kits.splitAllowed = false;
		st.kits.round++;
		return true;
	}
	st.kits.status = 'answered';
	return false;
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

export function kitsQuestion(st: MockChecks): KitsQuestion {
	return {
		round: st.kits.round,
		status: st.kits.status,
		k: st.kits.groups.length,
		splitAllowed: st.kits.splitAllowed,
		groups: st.kits.groups.map((g, c) => ({
			component: c,
			people: g.people,
			perMoment: g.perMoment,
			proposed: g.proposed,
			crops: g.kits.map((kit, n) => {
				const id = `c${c}_${String(n).padStart(2, '0')}`;
				return { id, image: `engine/crops/kits${st.kits.round}/${id}.svg`, imageUrl: dataUrl(personSvg(kit, n)) };
			})
		}))
	};
}
