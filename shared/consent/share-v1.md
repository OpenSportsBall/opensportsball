<!--
SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
SPDX-License-Identifier: Apache-2.0

Consent wording "share-v1": what the Mac app (and the website, for cloud
games) shows before a user shares results to improve the models. The API
accepts contributions only with a version listed in
api/src/lib/contributions.ts (CONSENT_VERSIONS); a changed wording gets a
new file and a new version, and contributions keep the version agreed to.

DRAFT (2026-11-09): not yet approved. Open decisions are marked [DECIDE].
-->

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
- It is kept until you withdraw it. [DECIDE: or for at most N years.]
- It is seen only by the people who build OpenSportsBall's models, to train
  and test them. [DECIDE: whether it may also go into OpenSportsBall's
  benchmark dataset, which is shared with researchers under its own terms.]
- You can withdraw anything you shared at any time, in the app or on the
  website (Account, Shared to improve OpenSportsBall), and closing your
  account withdraws all of it. A model already trained on it isn't undone.

[Read the privacy policy](https://opensportsball.com/privacy)
