# Mac app plan

A Mac app that turns a game's footage into the followed game video on the
user's own Mac, for free. It is the first local app; a Windows app comes
later, and a paid cloud service is offered next to both but never pushed.
The overall plan is in [PLAN.md](PLAN.md); open work in
[BACKLOG.md](BACKLOG.md).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Price | Local processing is free; the cloud (later) is paid and offered alongside, not pushed | |
| Account | Signed in, the same account as the phones | Footage, YouTube and contributions all hang off the account |
| Footage | Downloaded through the footage CloudFront distribution with the API's signed links | Already built (`POST .../recordings/{id}/downloads`, [API.md](API.md)); the phones need no changes |
| Minimum Mac | Apple Silicon (M1 or newer), 16 GB | Measured peak 8.4 GB with the ball stage and render overlapped; Intel Macs lack the GPU path |
| Pitch | The user approves our best guess at the lines, or marks the pitch, before every game | Wrong pitch geometry spoils everything after it; one check costs a minute |
| Kits | No "which is your team", and no kit check: the engine sorts the sides, keepers and referee itself | The camera follows play, not a team; the check that was here was removed on 2026-11-12 (see [Teams](#teams)) |
| Sharing | The pitch result is shared by default (a switch, on). Ball labels and must-see moments are only offered to users who agree to share them | The labels are only worth making for model training |
| Distribution | Notarized DMG with Sparkle updates, not the Mac App Store | The App Store's sandbox and review don't fit a bundled Python engine running for hours, and its terms conflict with the AGPL |

## Architecture

```
                 osb-engine (AGPL, opensportsball-processing)
   prepare: job.json -> questions/ (pitch guess)
   run:     job.json + answers.json -> sync, calibrate, ball, roles,
            follow, render -> game.mp4
   label:   job.json -> ball frames and must-see panoramas to label
   progress as JSON lines on stdout, resumable by chunk, exit codes
   Core ML / MPS (Mac), CUDA (cloud, Windows), CPU fallback
        ^                         ^                        ^
   Mac app (Flutter)       AWS Batch job           Windows app (later)
   runs it as a            S3 in and out;          runs it as a
   subprocess              questions on the web    subprocess
```

- **Licensing:** the app (Apache-2.0) runs the engine as a separate signed
  executable and talks to it only through files (job, questions, answers,
  labels, outputs) and progress lines, as [LICENSING.md](LICENSING.md)
  requires. The app links to the engine's source.
- **Shared formats:** `job`, `questions`, `answers`, `progress` and
  `contribution` schemas go in `shared/schemas/` next to the manifest. The
  engine computes and the app only draws, so the website can show the same
  questions when the cloud processes a game.
- **One job record:** local and cloud runs write the same job status to the
  API, so the website and phone app show "processing on your Mac" or "in
  the cloud", and a game done locally isn't processed again.

## The app, step by step

1. **Sign in** (Cognito).
2. **Pick a game** whose recording is `ready`. Download its segments and
   the merged manifest through the signed links; resume with range
   requests, check each file's sha256, and ask for fresh links after 12
   hours.
3. **Pre-flight:** Apple Silicon, 16 GB RAM, ~100 GB free disk (40-50 GB
   footage, ~22 GB output, working files), on mains power.
4. **Prepare** (`osb-engine prepare`): sync the phones, build the
   background panorama, fit the pitch, and group a sample of people by
   kit. Minutes, not hours (to be measured in step A below).
5. **Check the pitch** (required). See [Pitch check](#pitch-check).
6. **Process overnight** (`osb-engine run`): progress and time left, an
   `IOPMAssertion` to keep the Mac awake, pause on battery, resume after a
   quit or reboot, a notification at the end. The app says "overnight", not
   a time.
7. **Watch and deliver:** `game.mp4` on disk, the YouTube upload (Phase 5's
   flow), "done" to the API.
8. **Help improve tracking** (optional, sharing required): label the ball
   and mark must-see moments. See [Contributions](#ball-labels-and-must-see-moments).

### Pitch check

What the user sees: the background panorama (a median over the game, so
the players mostly vanish) with our fitted pitch drawn on it: touchlines,
goal lines, boxes, centre circle and goals, as `pitchtap/server.py`'s
review page draws it today.

- **Approve** if the lines sit on the paint.
- **Mark the pitch** if they don't: the app asks for named keypoints one at
  a time (the points `pitch.py`'s taps mode refits with: corners, box
  corners, the halfway line's ends, goalposts). Each one starts where the
  fit puts it; the user drags it to where it really is, or skips a point
  they can't see. The engine refits and the app shows the result again,
  until the user approves.
- **Line colour**, when the pitch has more than one: the engine's choice
  with each colour's detected lines, to confirm or change (`paint.json`
  today).
- **Share** switch, on by default: "Share this pitch map to help improve
  pitch detection." Shared: the background panorama, the fitted pitch
  (`pitch.json`), our first guess, the user's points and whether they
  approved or corrected it. Approving our guess unchanged is a useful
  result too: it is a measured success.

### Teams

There is no "which is your team" question, and no check of the teams: the
camera follows play, not a team. The engine sorts the two sides, the
keepers and the referee by kit colour itself (`teams.py`) and uses what it
finds. An earlier version showed the user the kit groups to check; it was
removed on 2026-11-12. Where the sorting is wrong (white kits, two shades
of one colour), the cost is in the processing repository's FINDINGS.md.

### Ball labels and must-see moments

Offered after the video is made, only to users who agree to share. Without
agreeing the screens stay locked and say why: these labels exist to train
the models. Agreeing names what is sent (frames and panoramas of the game,
which show players, often children) and links to the privacy policy; it can
be withdrawn later.

- **Ball labels:** frames picked like `labelset.py`'s "ball" mode: half
  where the detector found the ball (the engine's suggestions, so most
  labels are one tap), half where the tracker bridged a gap the detector
  missed (the hard cases). For each frame: tap the ball, pick a suggestion,
  or say "no ball visible". A set is 50 frames, each a few seconds; a
  progress bar shows how far through the set the user is.
- **Must-see moments:** while watching the game video, the user presses
  "Missed play" where the camera wasn't showing the play. The app shows the
  stitched panorama at that moment, and the user draws the part of the
  field the camera should have shown: the same must-see box
  `playeval.py` uses, stored in panorama degrees. A few random moments are
  added and boxed too, so the set doesn't only hold failures. These become
  the benchmark the follow cam is scored on.

Shared: the frames or panoramas, the labels, and the recording's camera
details needed to use them.

## What gets built

| Step | Work | Done when |
|---|---|---|
| A. Engine commands (3 wk) | `prepare`, `run` and `label` around `fullgame.py` and the steps before it; questions in, answers out; JSON progress, exit codes, resume; platform choices (GPU device, encoder, detector backend) in one module instead of hard-coded `h264_videotoolbox` and MPS | A whole game runs from the commands, with answers given as files and no hand edits |
| B. Engine side of the checks (2-3 wk) | Pitch: guess plus keypoint refit from answers. Kits: random crops per group, merge and split. Label sets for ball frames and must-see panoramas from a finished run | rec4, rec5 and rec7 go through prepare, answers and run untouched |
| C. Contributions backend (2 wk) | API to upload contributions and list or delete your own; storage kept apart from footage, with its own retention; the consent version recorded with each one; privacy policy section (see Privacy) | A contribution from the app lands where training can use it, and the user can delete it |
| D. Mac engine package (1-2 wk) | python-build-standalone, ffmpeg with VideoToolbox and the models in the .app, signed and notarized; Core ML exports made on first run (now automatic) or shipped | A clean Mac without Homebrew or uv processes a game |
| E. Mac app (5-7 wk) | Flutter macOS target: the steps above, including the pitch, kit, ball and must-see screens | A non-author goes from sign-in to YouTube and sends contributions; the rec7 fixture passes in CI (see [Testing and automation](#testing-and-automation)) |
| F. Cloud job (with D-E; PLAN.md Phase 3) | The same engine in a CUDA container on Batch; the same questions on the website | A game processes after upload, with the questions answered on the web |
| G. Windows (later, 4-6 wk) | CUDA build with a CPU / DirectML path, encoder per GPU vendor (nvenc / qsv / amf), MSIX or Velopack with Authenticode signing, `SetThreadExecutionState`, Defender and large files | As E, on a Windows PC |

## Testing and automation

The app has to be usable and testable without the three things a test (or
an LLM driving one) can't supply: a real account, 40-50 GB of footage and
an overnight run. Two audiences, two interfaces.

### Using it without the GUI

The engine is the interface for scripts and for a user's LLM: it already
takes a job file, writes `questions.json`, reads `answers.json` and prints
progress as JSON lines. The GUI is one client of it, not the only one.

- **`osb-engine` is callable by the user**, not only a binary inside the
  app bundle: the app offers to put it on the PATH, and the README says
  where it is.
- **A headless command for the steps only the app does today:** sign in,
  list games, download a recording (resume, sha256, fresh links). It
  shares the app's code for them, so there is one implementation.
- **Questions stand on their own:** each one carries the paths of its
  images (the pitch overlay and close-ups) and says in plain text what is
  being asked and what the answers mean, so a model that reads images can
  answer the pitch check from the files alone.
- **Later, if wanted:** an MCP server over those commands. It is a thin
  layer once they exist.

### Testing the GUI

1. **A replay engine.** The app talks to the engine through one interface
   with two implementations: the real subprocess, and one that plays back
   a recorded run (the event lines, `questions.json` and its images, the
   label sets) at any speed, including the failures (`footage_corrupt`,
   `not_enough_disk`, a step failing, a stop and resume). Fixtures are
   captured from real games (rec7 first; rec5 for the no-stitch path) and
   kept small: thumbnails, not footage.
2. **Launch-time fixtures.** Debug builds take flags such as
   `--fake-account --fixture rec7 --start-at pitch-check`, so a test lands
   on any screen in a known state with no sign-in, download or wait. The
   fake account and API build on the phone app's test fakes
   (`app/test/fakes.dart`, `upload_fakes.dart`).
3. **Driver hooks, debug builds only.** Every control has a stable key and
   a semantics label (also the accessibility work), and the Flutter driver
   extension is on. A test, or an LLM through the Dart and Flutter MCP
   server (check its current tool list), can then read the widget tree,
   tap by key, type and take screenshots. Release builds carry none of
   this.

The same fixtures run as `integration_test` suites in the Mac app's CI:
one pass through every screen per fixture, with a screenshot of each.

Not planned: driving the window by screen coordinates (slow, breaks on
every layout change), or a Flutter web build for browser tools to click
(the app's core is a subprocess and large files, which the web build
doesn't have, so it would test a different app).

Done when: a fresh checkout runs the app from sign-in to "done" against
the rec7 fixture in under a minute, in CI and from an LLM session, and a
whole game runs from the headless commands with answers given as files.

## Privacy

The current policy promises footage is deleted 180 days after upload or
when the user deletes it, and never shared. Contributions break both
unless the policy says how they're different. Before C ships:

- A policy section for "data you share to improve the models": what is
  sent (pitch maps and panoramas, people crops, frames, labels), that it
  shows people, often children, that it is kept apart from footage and
  not deleted when the game is, for how long, who can see it, and how to
  withdraw it (delete your contributions in the app or on the website).
- Consent recorded per contribution with the wording's version.
- A decision on whether contributed data may go into the shared benchmark
  dataset (today a gated Hugging Face dataset), or stays private to the
  project. The consent text has to match.
- Only adults hold accounts, and they agree they're allowed to record the
  players (as the policy already says); sharing adds no new kind of
  person, but it does keep images longer and in another place.

## Keeping Windows and the cloud cheap later

- Platform choices live in one module, tested per platform.
- The ONNX export path stays working next to Core ML: ONNX Runtime with
  CUDA or DirectML is the likely Windows path, and it gave identical
  detections in the Mac benchmark.
- The Flutter shell only reads progress lines and question files, so most
  of the Mac app, check screens included, carries over to Windows.
- Questions and answers are files, so the website can show them for cloud
  games.

## Risks

- Ball colours the models haven't seen still need labels. Until
  contributions arrive, a new ball colour can track poorly; the label
  screens are how that gets fixed.
- Run time: 5-6 h per game before the Core ML change (the ball and roles
  stages are ~30% faster since; a full game is not yet measured).
- Download cost: free local processing still downloads 40-50 GB a game
  through CloudFront. The first 1 TB a month is free (~20 games), then
  about $0.085/GB (~$4 a game). Watch it on the cost dashboard.
- Contribution volume and quality: the share switches being on by default
  helps volume; scoring labels against each other (a frame labelled twice)
  catches careless ones.
