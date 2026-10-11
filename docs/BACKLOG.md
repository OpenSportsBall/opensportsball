# Backlog

Open work, roughly in priority order within each section. Phases refer to
[PLAN.md](PLAN.md). When an item is done, delete it here and mention it in
the commit.

## Testing on phones (now)

Footage and logs from these tests decide several items below.

- [ ] Install on the second Pixel; pair; paired recording with synchronized
      start ([TESTING-APPS.md](TESTING-APPS.md) tests 2-8).
- [ ] Dark-screen mode on both phones; confirm no glitch in the recording
      when the screen darkens.
- [ ] Dropped link (Bluetooth off on Secondary for 30 s), out of range, and
      interruption (incoming call) tests.
- [ ] 90-minute 4K run on the mount, outdoors if possible: temperature,
      battery, storage.
- [ ] First real website sign-up (Cognito), link both phones, upload a
      recording on Wi-Fi, game reaches Ready.

## Bugs and small fixes

- [ ] Delete the old `SportsBallVideo` stack (us-west-2) now that
      `OpenSportsBall` is live (deployed 2026-10-11, verified end to end).
      Its footage bucket, table and user pool are retained by design and
      must be deleted separately; all three are empty.
- [ ] Uninstall the old `dev.sportsballvideo.sportsballvideo` app from the
      Pixel 11 once its test recordings are no longer needed (the rebrand
      changed the application id, so both are installed).

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

- [ ] Background upload: WorkManager with a foreground-service notification
      (Android), background `URLSession` (iOS). Today uploads run only while
      the app is open.
- [ ] Register the `opensportsball://link` deep link so the phone's own
      camera app can open the link QR code.
- [ ] Recordings recovered after a crash upload their segments but have no
      manifest, so they are never processed. Let Main write a manifest for
      them (at least a one-device one).
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

## Phase 0: feasibility on real footage

- [ ] Record a real game with both phones on the mount.
- [ ] Prototype audio sync, stitching and players-only follow in a notebook.

## Phase 3: processing pipeline

- [ ] GPU Spot quota: request for 8 vCPUs of G instances in `us-west-2` is
      **pending** with AWS (filed 2026-10-06). Needed before any GPU job runs.
- [ ] Batch GPU job (sync, calibrate, detect, camera path, render),
      Step Functions triggered by `RecordingReady`.
- [ ] Lifecycle rule deleting raw footage N days after a successful render.
- [ ] Verify each segment's SHA-256 against the manifest on download.
- [ ] Android footage: expect ~150 ms missing at every segment switch and
      start times that drift by that much per switch (see the gap-free
      recorder item). Re-sync each segment to the other phone by audio
      cross-correlation rather than trusting `startedAtDeviceMs`, and
      tolerate the undecodable leading frames at the start of segments
      after the first.

## Phase 4-6

- [ ] Ball detection: fine-tune on youth-game footage; Kalman tracking;
      blended camera target.
- [ ] YouTube: OAuth connect, Fargate upload task, notifications; default
      privacy unlisted/private.
- [ ] Hardening: retries, Spot-interruption checkpoints, cost dashboard,
      self-host docs.

## Project and operations

- [ ] CLA text (based on the Apache Individual CLA) and CLA Assistant,
      before the repo goes public. The repo stays local until then.
- [ ] `CLAUDE.md` for the repo: licensing split, API contract, how to run
      each part's tests, deployed stack.
- [ ] Cognito sends verification email from its built-in sender (low daily
      limit). Switch to SES before more than a handful of families use it.
- [ ] `bluetooth_low_energy_android` applies the Kotlin Gradle plugin, which
      a future Flutter release will reject. Track an update or replace it.
- [ ] Flutter has a newer release available; upgrade and re-run all checks.
