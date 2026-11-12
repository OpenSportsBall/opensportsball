// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Sharing a check's result to improve the models: the wording people agree
 * to before anything is shared. It is shared/consent/share-v1.md after its
 * comment, word for word (a test compares the two), as in the Mac app. A
 * changed wording is a new file and a new version, agreed again.
 */

export const SHARE_CONSENT_VERSION = 'share-v1';

export const SHARE_CONSENT_TEXT = `
# Share this to improve OpenSportsBall

To get better at mapping pitches, telling teams apart, finding the ball and
following the play, OpenSportsBall's models learn from real games. If you
agree, the app sends what you checked or labelled for this game:

- **Pitch check:** the empty-pitch panorama, the lines we fitted, and the
  points you marked.
- **Kit check:** small pictures of people on the pitch, grouped by kit, and
  your corrections.
- **Ball labels:** still frames from the game and where you marked the
  ball.
- **Must-see moments:** panoramas of the game at those moments and the boxes
  you drew.

These are pictures of the game, so **they show the players, who are often
children, and anyone else in view.** Share only if you are allowed to
record them (as you already agree when you record).

What happens to it:

- It is kept apart from your game's footage, and **it is not deleted when
  you delete the game or the recording**: that's what makes it useful for
  training.
- It is kept until you withdraw it or close your account, or until your
  account has gone unused for 3 years.
- It is used only to train and test OpenSportsBall's models, and seen only
  by the people who build them. It is not published or shared outside the
  project.
- You can withdraw anything you shared at any time, in the app or on the
  website (Account, Shared to improve OpenSportsBall), and closing your
  account withdraws all of it. A model already trained on it isn't undone.

[Read the privacy policy](https://opensportsball.com/privacy)
`;

/** One block of the wording: its heading, a paragraph, a bullet or a link. */
export interface ConsentBlock {
	kind: 'heading' | 'paragraph' | 'bullet' | 'link';
	/** Runs of text; `bold` for the parts between ** **. */
	runs: { text: string; bold: boolean }[];
	url?: string;
}

const runs = (text: string) =>
	text
		.split('**')
		.map((t, i) => ({ text: t, bold: i % 2 === 1 }))
		.filter((r) => r.text);

/** The wording's few kinds of Markdown: a `#` heading, paragraphs, `-`
 *  bullets (continued on indented lines), `**bold**` and one link line. */
export function consentBlocks(markdown: string = SHARE_CONSENT_TEXT): ConsentBlock[] {
	const out: ConsentBlock[] = [];
	let kind: ConsentBlock['kind'] | null = null;
	let buf: string[] = [];
	const flush = () => {
		if (kind && buf.length) out.push({ kind, runs: runs(buf.join(' ')) });
		kind = null;
		buf = [];
	};
	for (const line of markdown.split('\n')) {
		const t = line.trim();
		const link = /^\[(.+)\]\((https:\/\/[^)]+)\)$/.exec(t);
		if (!t) flush();
		else if (link) {
			flush();
			out.push({ kind: 'link', runs: runs(link[1]), url: link[2] });
		} else if (line.startsWith('# ')) {
			flush();
			out.push({ kind: 'heading', runs: runs(line.slice(2)) });
		} else if (line.startsWith('- ')) {
			flush();
			kind = 'bullet';
			buf = [line.slice(2)];
		} else {
			kind ??= 'paragraph';
			buf.push(t);
		}
	}
	flush();
	return out;
}

const AGREED_KEY = `osb-agreed-${SHARE_CONSENT_VERSION}`;

/** Whether this browser's user has read and agreed to this wording before. */
export function hasAgreedToShare(): boolean {
	try {
		return localStorage.getItem(AGREED_KEY) === 'yes';
	} catch {
		return false;
	}
}

export function rememberAgreedToShare(): void {
	try {
		localStorage.setItem(AGREED_KEY, 'yes');
	} catch {
		/* storage blocked: they are asked again next time */
	}
}
