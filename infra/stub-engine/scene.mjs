// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

// A made-up game for the stub engine, in the real engine's formats
// (shared/schemas/engine-questions.schema.json): a drawn pitch whose first
// "fit" is visibly off at the right-hand end. Enough for the website's
// pitch check to have something to approve and correct. No footage is read.

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
