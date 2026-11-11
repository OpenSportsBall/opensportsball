// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Mock mode only (lib/mock.ts): the made-up game the checks are shown for.
 * The same scene the stub engine writes (infra/stub-engine/scene.mjs): a
 * drawn pitch whose first "fit" is off at the right-hand end, and three kit
 * groups, one of them two kits mixed together. Pictures are data URLs.
 */
import type { KitsQuestion, PitchKeypoint, PitchQuestion, Point } from './types';

export const WIDTH = 2000;
export const HEIGHT = 600;

export type PitchPoints = Record<string, Point>;

const TRUE_POINTS: PitchPoints = {
	near_left_corner: [150, 520],
	near_right_corner: [1850, 520],
	far_left_corner: [520, 250],
	far_right_corner: [1480, 250],
	halfway_near: [1000, 520],
	halfway_far: [1000, 250]
};

const LABELS: Record<string, string> = {
	near_left_corner: 'Near left corner',
	near_right_corner: 'Near right corner',
	far_left_corner: 'Far left corner',
	far_right_corner: 'Far right corner',
	halfway_near: 'Halfway line, near side',
	halfway_far: 'Halfway line, far side'
};

/** The first guess: right at the left end, off at the right. */
export const firstFit = (): PitchPoints => ({
	...structuredClone(TRUE_POINTS),
	near_right_corner: [1905, 536],
	far_right_corner: [1552, 228],
	halfway_far: [1022, 242]
});

function pitchLines(p: PitchPoints): Point[][] {
	return [
		[p.near_left_corner, p.near_right_corner],
		[p.far_left_corner, p.far_right_corner],
		[p.near_left_corner, p.far_left_corner],
		[p.near_right_corner, p.far_right_corner],
		[p.halfway_near, p.halfway_far]
	];
}

const dataUrl = (svg: string) => `data:image/svg+xml,${encodeURIComponent(svg)}`;
const path = (pts: Point[]) => pts.map(([x, y], i) => `${i ? 'L' : 'M'}${x} ${y}`).join(' ');

function pitchSvg(): string {
	const paint = pitchLines(TRUE_POINTS)
		.map((l) => `<path d="${path(l)}" stroke="#f4f4ec" stroke-width="5" fill="none" stroke-linecap="round"/>`)
		.join('');
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${WIDTH} ${HEIGHT}" width="${WIDTH}" height="${HEIGHT}">
<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9cc3e6"/><stop offset="1" stop-color="#dbe9f4"/></linearGradient>
<linearGradient id="turf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3f8a45"/><stop offset="1" stop-color="#2f6f37"/></linearGradient></defs>
<rect width="${WIDTH}" height="200" fill="url(#sky)"/>
<rect y="170" width="${WIDTH}" height="40" fill="#3c5a3a"/>
<rect y="200" width="${WIDTH}" height="400" fill="url(#turf)"/>
${paint}
<ellipse cx="1000" cy="372" rx="150" ry="52" stroke="#f4f4ec" stroke-width="5" fill="none"/>
<text x="24" y="44" font-family="sans-serif" font-size="28" fill="#1d3b5a">Mock data: a drawn pitch, not footage</text>
</svg>`;
}

export function pitchQuestion(points: PitchPoints, round: number): PitchQuestion {
	const keypoints: PitchKeypoint[] = Object.entries(points).map(([id, [x, y]]) => ({ id, label: LABELS[id], x, y }));
	return {
		round,
		text:
			'This is the pitch with our best guess at its lines drawn on it. Do the drawn lines sit on the painted lines? ' +
			'If not, put each named point where it really is, or say you cannot see it.',
		image: 'pitch.svg',
		imageUrl: dataUrl(pitchSvg()),
		width: WIDTH,
		height: HEIGHT,
		lines: pitchLines(points),
		keypoints
	};
}

type Kit = 'blue' | 'red' | 'green' | 'orange' | 'yellow';
const KITS: Record<Kit, [string, string]> = {
	blue: ['#1f5fbf', '#1f5fbf'],
	red: ['#c62828', '#c62828'],
	green: ['#1b8a3a', '#f4f4ec'],
	orange: ['#ef7d1a', '#ef7d1a'],
	yellow: ['#f2c61f', '#222222']
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
export interface KitGroup {
	id: string;
	kits: Kit[];
}

/** Blue with one red player in it, red with the referee in it, and one
 *  group that is two kits (green and orange). */
export const firstGroups = (): KitGroup[] => [
	{ id: 'g0', kits: Array.from({ length: PEOPLE }, (_, i) => (i === 7 ? 'red' : 'blue')) },
	{ id: 'g1', kits: Array.from({ length: PEOPLE }, (_, i) => (i === 3 ? 'yellow' : 'red')) },
	{ id: 'g2', kits: Array.from({ length: PEOPLE }, (_, i) => (i % 2 ? 'orange' : 'green')) }
];

export function splitGroup(groups: KitGroup[], id: string): KitGroup[] {
	return groups.flatMap((g) => {
		const kinds = [...new Set(g.kits)];
		if (g.id !== id || kinds.length < 2) return [g];
		return kinds.slice(0, 2).map((kind, i) => ({ id: `${g.id}${'ab'[i]}`, kits: Array.from({ length: PEOPLE }, () => kind) }));
	});
}

export function kitsQuestion(groups: KitGroup[], round: number, canSplit: boolean): KitsQuestion {
	return {
		round,
		text:
			'Each group should be one kit. Mark anyone who is in the wrong group or is not a player in kit. ' +
			'Then say whether every kit has exactly one group, two groups are the same kit, or one group has two kits in it.',
		canSplit,
		groups: groups.map((g) => ({
			id: g.id,
			people: g.kits.map((kit, i) => {
				const id = `p${String(i).padStart(2, '0')}`;
				return { id, image: `kits/${g.id}/${id}.svg`, imageUrl: dataUrl(personSvg(kit, i)) };
			})
		}))
	};
}
