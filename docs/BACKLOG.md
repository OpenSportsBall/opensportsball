# Backlog

Open work, roughly in priority order within each section. Phases refer to
[PLAN.md](PLAN.md). When an item is done, delete it here and mention it in
the commit. Processing and ML work (Phase 0 and the pipeline itself) is
tracked in the opensportsball-processing repository's `docs/BACKLOG.md`.

## Testing on phones (now)

Footage and logs from these tests decide several items below.

- [ ] Install on the second Pixel; pair; paired recording with synchronized
      start ([TESTING-APPS.md](TESTING-APPS.md) tests 2-8).
- [ ] Dark-screen mode on both phones; confirm no glitch in the recording
      when the screen darkens.
- [ ] Dropped link (Bluetooth off on Secondary for 30 s), out of range, and
      interruption (incoming call) tests.
- [ ] First real website sign-up (Cognito), link Main (it gives Secondary
      a recording grant), upload a recording on Wi-Fi, game reaches Ready.
      Also pair with a Secondary on another account, and on none.

- [ ] Pairing without signal (built 2026-10-20, grant tickets): open
      Main once online so it stocks tickets, then put both phones in
      airplane mode with Bluetooth on, pair, record, stop. Main should
      show "to this phone's account (confirmed once online)". Back on
      Wi-Fi, both upload and the game reaches Ready. Needs the backend
      deployed with `POST /grant-tickets` and `POST /grants/redeem`.

- [ ] Upload permission link (built 2026-10-28): record with Main not
      linked (Secondary shows "Waiting for upload permission"), let Main's
      part finish (Ready). On the website's game page, get the link, open
      it on the Secondary, tap Open in the app. Secondary uploads; the
      game shows both phones and is Ready again. Also scan the QR from
      another screen, and open the link on a phone with no recording of
      that game (the app says so and the link still works elsewhere).

- [ ] Upside-down phone plays upright: record with the new build and
      check the Secondary's segments open the right way up in QuickTime
      and the website (Android orientation hint / iOS track transform from
      the orientation read while the preview is open).

## Bugs and small fixes

- [ ] Uninstall the old `dev.sportsballvideo.sportsballvideo` app from the
      Pixel 11 once its test recordings are no longer needed (the rebrand
      changed the application id, so both are installed).

- [ ] BLE sends are one serialized chain with no timeout
      (`app/lib/src/link/ble_link.dart`, `send`): one write that never
      completes blocks everything after it. Seen 2026-10-11: Main heard
      nothing from Secondary after Prepared (Start/Stop still arrived).
      Uploads no longer depend on it, but Main's screen does. Add a
      per-write timeout and reconnect on it.
- [ ] Android: "MediaRecorder.stop failed" logged when Stop lands just
      after a file-size warning (the pre-armed next file is empty). Recording
      is intact; handle it quietly and delete any empty next file.
- [ ] Main screen: no way to reach Settings or see the segment length;
      settings are read only when the screen opens. Add a settings button
      (or a summary line) on the Main screen.
- [ ] `stoppedAtMs` is written after the last segment is hashed (about 15 s
      later per GB), not when Stop is pressed. Record the press time.
- [ ] Pairing panel: the status line under the QR code can be pushed off
      screen on short displays.

## App features

- [ ] Test background upload on an iPhone (iOS 26; see `app/README.md`):
      record, stop, leave the app / lock the phone, check the system
      progress item and that the upload finishes. Android passed on the
      Pixel 11 (2026-10-11: swiped away, phone locked). If iOS ends the
      task too often, move part PUTs to a background `URLSession`.
- [ ] Secondary's owner sees the games they contributed to. With
      recording grants, a Secondary on another account uploads into Main's
      account, so its owner has no record of the footage. Show a
      "Contributed to" list on the website (game, date, Main's account
      name, status) with view access to the processed video, and optionally
      the raw segments that phone recorded. Main's account can revoke it.
      Decide whether access lasts after Main deletes the game.
- [ ] Register the `opensportsball://link` deep link so the phone's own
      camera app can open the link QR code.
- [ ] **Android gap-free recorder: only if the switch gaps prove visible
      and disruptive** in real game footage or the rendered output. Decided
      2026-10-10 to keep MediaRecorder for now.
      - Measured on a Pixel 11 (stopwatch, 1-minute segments): each segment
        switch loses about 4-5 frames (0.16 s and 0.20 s). MediaRecorder's
        `setNextOutputFile` starts each new file at a CRA whose leading
        (RASL) frames reference pictures in the previous file, so they cannot
        be decoded; joining the files with a stream copy does not recover
        them.
      - At 5-minute segments: ~18 switches per 90-minute game, ~2.7 s lost
        in total, and per-segment start times drift by the same amount
        because later segments' `startedAtDeviceMs` is the previous start
        plus its measured duration.
      - Fix: replace MediaRecorder with MediaCodec (video + AAC) and
        MediaMuxer. Request a sync frame (IDR, closed GOP) at each boundary
        and start the new muxer on it; stamp each segment from the camera's
        sensor timestamps; cut on exact duration. Then lower the default
        segment length to 2 minutes (crash loss is one segment, since an
        unfinalized Android MP4 is unplayable).
      - Verify with the same stopwatch test: zero missing frames across
        switches, and segment start times matching the stopwatch.

## Phase 3: processing pipeline

- [ ] On-demand GPU quota: request G instances in `us-west-2`, the
      fallback when Spot has none (the Spot quota was granted 2026-11-10).
- [ ] Cloud processing ([CLOUD-PROCESSING-PLAN.md](CLOUD-PROCESSING-PLAN.md)).
      Steps 1-3 are deployed with the stub engine. Step 4 (the real
      engine's wrapper and image, and the engine's own question and answer
      formats here) is built and tested locally, not deployed and not run
      on a GPU. Next: the plan's "Left" list, starting with a recording
      through the stub and a one-chunk GPU run.
- [ ] Privacy policy: say what cloud processing keeps (the game video and
      the checks' pictures, 180 days from when they are made, deleted with
      the recording). Before cloud processing is on for anyone but us.
- [ ] Lifecycle rule deleting raw footage N days after a successful render.

## Local apps (docs/MAC-APP-PLAN.md)

- [x] Contributions backend (step C), 2026-11-09, not deployed: `POST
      /contributions` (signed PUT per file, size and SHA-256 enforced by
      S3), `.../complete`, `GET`, `DELETE` (withdraw); its own `Contributions`
      bucket, kept on stack delete, not expired with footage; deleted with
      the account; `ContributionReady` logged. The website's Account page
      lists them with Withdraw; the privacy policy has a draft section; the
      consent wording is `shared/consent/share-v1.md` (draft).
- [x] Decided 2026-11-10 (privacy policy and `share-v1` say the same): shared
      results are kept until withdrawn, the account is deleted, or the
      account goes unused for 3 years, with no fixed cap (training and
      stable benchmarks need them); used only inside the project, for
      training and its own held-out benchmarks, never published.
- [x] `share-v1`'s wording approved and the privacy policy dated
      (November 10, 2026), 2026-11-10.
- [ ] Deploy C with the next deploy (the privacy section goes live with
      it). A lawyer reading the policy section and `share-v1` is still
      worth it: the pictures show children.
- [ ] Inactivity sweep, needed before the first contribution is 3 years old
      (the policy promises it): an account-level `lastActiveAt` (website
      sign-in, app sign-in, any linked phone or Mac calling the API; devices
      already have `lastSeenAt`), and a scheduled job deleting
      `contributions/<accountId>/` for accounts idle 3 years. Optionally
      email a warning a month before.
- [ ] Benchmark versions: when a withdrawal removes test items, the
      held-out set gets a new version and records what it lost, so scores
      stay comparable.
- [ ] Sharing contributions outside the project (the gated Hugging Face
      benchmark dataset): only with a separate opt-in, its own consent
      wording and a legal review. Not planned.
- [ ] Contributions left `uploading` (the app quit before `complete`): sweep
      them after a few days, or let the app resume them.
- [ ] Training's read path: how the processing repo pulls complete
      contributions (an admin role reading `contributions/`, or a script on
      `ContributionReady`) and records which consent version each came with.
- [x] Mac app (step E), first slice, 2026-11-10: `desktop/` (Flutter, macOS)
      and `packages/osb_core/` (plain Dart: sign-in with PKCE and refresh,
      the API, the resumable footage download with SHA-256 checks, the
      engine driver). Sign in, the games list, pre-flight checks, download,
      prepare, the cameras / pitch / kit checks, the overnight run (kept
      awake, paused on battery, resumed after a quit), the video in the
      Finder. A `Desktop` Cognito client (30-day refresh) in infra and
      `desktopClientId` in config.json. `OSB_DEMO_RECORDING` serves a local
      recording through a stand-in API for development; `test/e2e_test.dart`
      runs it through the real engine.
- [ ] Deploy the `Desktop` client, then sign in from the Mac app against
      the real site and process a real game end to end.
- [x] Put the engine in the app (`Contents/Resources/osb-engine`,
      `desktop/macos/copy_engine.sh`), 2026-11-10.
- [x] Release tooling, 2026-11-10: `desktop/tool/release_mac.sh` signs the
      app and every engine binary with the hardened runtime, makes the DMG,
      notarizes it and writes the Sparkle appcast; Sparkle updates from the
      GitHub releases (desktop/README.md "Releasing"). Tried with an Apple
      Development certificate: the signed engine prepares a game, and a
      0.1.0 test build updated itself to 0.1.1.
- [x] `osb` (sign in, list games, download without the window:
      `packages/osb_core/bin/osb.dart`) and, 2026-11-10, built into the app
      at `Contents/MacOS/osb` (`desktop/macos/build_osb.sh`); the release
      script signs it with `macos/Osb.entitlements`. Tried with an ad-hoc
      signature only; the release script itself hasn't been run since.
- [ ] `osb` against the real site (needs the `Desktop` client deployed with
      the localhost callbacks), and `osb` and `osb-engine` on the PATH for
      people who ask: small launcher scripts, as the engine's launcher
      doesn't follow a symlink.
- [ ] First public Mac release: a Developer ID Application certificate, the
      Sparkle update key (its public half in AppInfo.xcconfig), notarize,
      publish `mac-v0.1.0`.
- [ ] One job record (MAC-APP-PLAN "Architecture"): the app writes "processing
      on your Mac" and "done" to the API, so the website and phones show it and
      a game isn't processed twice.
- [ ] A notification when the video is ready (UserNotifications).
- [x] The ball, while the game is processed, 2026-11-10: from the second
      segment the app says when the engine doesn't know this ball (the
      engine's `ball` event, `ballLow`), a Segments view lists each chunk's
      two stages, times, logs and ball share (`status`'s `chunkDetails`),
      and "Mark the ball" labels a ball set (`engine.py label ball`, also
      while the game is still running): click the ball or the engine's
      ring, or say it isn't there. Locked until sharing is agreed.
- [x] Sending what was agreed, 2026-11-10: the app shows the share-v1
      wording (word for word, checked by a test), and once agreed sends
      the pitch map and the kit groups (each check's switch) and the ball
      sets with marks: `engine.py share` lists them, `POST /contributions`,
      a PUT per file, `complete` (packages/osb_core `contributions.dart`).
      A changed result is sent again and the older copy withdrawn; each
      game has a card saying what it shared, with Withdraw.
      `engine/share/sent.json` records it. Tried only against a stand-in
      API: the contributions backend isn't deployed.
- [ ] Deploy the contributions backend, then share from a real game and
      withdraw it, from the app and from the website.
- [ ] Must-see moments (`engine.py label moments`); sent like the rest.
- [ ] `osb share` and `osb withdraw` for the command line, on the same
      code (the consent has to be shown and agreed there too).
- [ ] When the video is made, offer to delete the downloaded footage (~40 GB).
- [ ] The phone app uses `osb_core` (sign-in, URL helpers) and both apps take
      the brand theme and fonts from one shared package
      (`desktop/lib/src/brand.dart` is a copy of the phone's).

## Phase 4-6

- [ ] YouTube: OAuth connect, Fargate upload task, notifications; default
      privacy unlisted/private.
- [ ] Hardening: retries, Spot-interruption checkpoints, cost dashboard,
      self-host docs.

## Project and operations

- [ ] CDK's deploy-time helper Lambdas (bucket deployment, bucket
      notifications, auto-delete) log to groups CloudFormation doesn't own,
      with no retention; they outlive the stack. Give them a retention
      policy, or clean them up when a stack is deleted (did this by hand for
      the old `SportsBallVideo` stack, 2026-10-11).

- [ ] Before the repos go public: CLA Assistant (cla-assistant.io) on
      both repos, signing from a gist of `CLA.md`. The repos stay private
      on GitHub until then.
- [ ] `CLAUDE.md` for the repo: licensing split, API contract, how to run
      each part's tests, deployed stack.
- [ ] Cognito sends verification email from its built-in sender (low daily
      limit). Switch to SES before more than a handful of families use it.
- [ ] `bluetooth_low_energy_android` applies the Kotlin Gradle plugin, which
      a future Flutter release will reject. Track an update or replace it.
- [ ] Flutter has a newer release available; upgrade and re-run all checks.
