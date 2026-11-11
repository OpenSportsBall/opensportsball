// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

// A made-up game for the stub engine, in the real engine's formats
// (shared/schemas/engine-questions.schema.json): a drawn pitch whose first
// "fit" is visibly off at the right-hand end, and kit groups, one of them
// two kits mixed together. Enough for the website's checks to have
// something to approve, correct, split and merge. No footage is read.

export const WIDTH = 2000;
export const HEIGHT = 600;
/** The picture's pixels and panorama degrees, as the engine describes its background. */
export const PANORAMA = { image: 'background.svg', degPerPx: 0.1, yawRange: [-100, 100], pitchRange: [-20, 40] };

export const toDeg = ([x, y]) => ({
  yaw: Math.round((PANORAMA.yawRange[0] + x * PANORAMA.degPerPx) * 1000) / 1000,
  pitch: Math.round((PANORAMA.pitchRange[0] + y * PANORAMA.degPerPx) * 1000) / 1000,
});
export const toPx = ({ yaw, pitch }) => [
  (yaw - PANORAMA.yawRange[0]) / PANORAMA.degPerPx,
  (pitch - PANORAMA.pitchRange[0]) / PANORAMA.degPerPx,
];

/** Where the painted pitch really is in the picture, in pixels. */
export const TRUE_POINTS = {
  'left corner flag': [150, 520],
  'right corner flag': [1850, 520],
  'far left corner flag': [520, 250],
  'far right corner flag': [1480, 250],
  'halfway near end': [1000, 520],
  'halfway far end': [1000, 250],
};

/** The first guess: right at the left end, off at the right. */
export const FIRST_FIT = {
  ...TRUE_POINTS,
  'right corner flag': [1905, 536],
  'far right corner flag': [1552, 228],
  'halfway far end': [1022, 242],
};

const MARKINGS = [
  ['left corner flag', 'right corner flag'],
  ['far left corner flag', 'far right corner flag'],
  ['left corner flag', 'far left corner flag'],
  ['right corner flag', 'far right corner flag'],
  ['halfway near end', 'halfway far end'],
];

/** The pitch markings for a set of points, as polylines in pixels. */
export const linesPx = (pts) => MARKINGS.map(([a, b]) => [pts[a], pts[b]]);

const path = (pts) => pts.map(([x, y], i) => `${i ? 'L' : 'M'}${x} ${y}`).join(' ');
const stroke = (lines, colour, width) =>
  lines.map((l) => `<path d="${path(l)}" stroke="${colour}" stroke-width="${width}" fill="none" stroke-linecap="round"/>`).join('');

/** The "background panorama" (sky, turf, the painted lines), and with
 *  `fit` the overlay: the same with the fitted pitch drawn on in red. */
export function pitchSvg(fit) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${WIDTH} ${HEIGHT}" width="${WIDTH}" height="${HEIGHT}">
<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9cc3e6"/><stop offset="1" stop-color="#dbe9f4"/></linearGradient>
<linearGradient id="turf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3f8a45"/><stop offset="1" stop-color="#2f6f37"/></linearGradient></defs>
<rect width="${WIDTH}" height="200" fill="url(#sky)"/>
<rect y="170" width="${WIDTH}" height="40" fill="#3c5a3a"/>
<rect y="200" width="${WIDTH}" height="400" fill="url(#turf)"/>
${stroke(linesPx(TRUE_POINTS), '#f4f4ec', 5)}
<ellipse cx="1000" cy="372" rx="150" ry="52" stroke="#f4f4ec" stroke-width="5" fill="none"/>
${fit ? stroke(linesPx(fit), '#e0261c', 4) : ''}
<text x="24" y="44" font-family="sans-serif" font-size="28" fill="#1d3b5a">Stub engine: a drawn pitch, not footage</text>
</svg>`;
}

const KITS = {
  blue: ['#1f5fbf', '#1f5fbf'],
  red: ['#c62828', '#c62828'],
  green: ['#1b8a3a', '#f4f4ec'],
  orange: ['#ef7d1a', '#ef7d1a'],
  yellow: ['#f2c61f', '#222222'],
  grey: ['#8a8f98', '#8a8f98'],
};

/** One person crop: a figure in a kit on turf. */
export function personSvg(kit, n) {
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
const group = (kits, people, perMoment, proposed) => ({ kits, people, perMoment, proposed });
const all = (kit) => Array.from({ length: PEOPLE }, () => kit);

/** The first grouping: blue with one red player in it, red, one group
 *  that is two kits (green and orange), the keepers and referee in yellow,
 *  and people in grey who aren't players. */
export const FIRST_GROUPS = [
  group(all('blue').map((k, i) => (i === 7 ? 'red' : k)), 412, 10.6, 'A'),
  group(all('red'), 388, 9.8, 'B'),
  group(all('green').map((k, i) => (i % 2 ? 'orange' : k)), 97, 2.4, 'other'),
  group(all('yellow'), 61, 1.6, 'keeperOrReferee'),
  group(all('grey'), 33, 0.7, 'other'),
];

/** Group [component] split into its two kits; the rest keep their places. */
export function splitGroup(groups, component) {
  return groups.flatMap((g, c) => {
    const kinds = [...new Set(g.kits)];
    if (c !== component || kinds.length < 2) return [g];
    return kinds.slice(0, 2).map((kind) => group(all(kind), Math.round(g.people / 2), g.perMoment / 2, 'other'));
  });
}

/** The kit groups as questions.json lists them, and the pictures to write. */
export function kitFiles(groups, round) {
  const files = [];
  const listed = groups.map((g, c) => ({
    component: c,
    people: g.people,
    perMoment: g.perMoment,
    proposed: g.proposed,
    crops: g.kits.map((kit, n) => {
      const id = `c${c}_${String(n).padStart(2, '0')}`;
      const image = `engine/crops/kits${round}/${id}.svg`;
      files.push({ path: image, body: personSvg(kit, n) });
      return { id, image };
    }),
  }));
  return { groups: listed, files };
}
