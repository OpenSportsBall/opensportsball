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
- [ ] First real website sign-up (Cognito), link Main (it gives Secondary
      a recording grant), upload a recording on Wi-Fi, game reaches Ready.
      Also pair with a Secondary on another account, and on none.

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
- [ ] Recording grants need Main online at some point while the phones
      are paired. If fields without signal turn out to be common, let Main
      fetch a few unbound grant tickets ahead of time, each bound to one
      phone and game on first use.
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

## Phase 0: feasibility on real footage

- [ ] Record a full real game with both phones on the mount, mounted
      higher. First field clip (2026-10-12, recording `7fb5bc20`, 5 min,
      two segments per phone) was shot near ground level: both goals fit
      in the panorama, but players are small and the near touchline is
      ~1-2 m away.
- [ ] `processing/spikes/phase0.py` findings on that clip, to carry into
      the pipeline:
      - Audio sync locks cleanly outdoors (sharpness 8-29 per 4 s window).
      - Offset drifts about -6 ppm (~30 ms per 90 min, one frame), and
        segment 0 has a 5.5 ms step at ~115 s (an audio discontinuity on
        one phone). Sync piecewise (per window, then fit), not one offset
        per segment.
      - The offset jumps 128 ms between segment 0 and 1: the phones lose
        different amounts at the switch, and `startedAtDeviceMs` doesn't
        show it (BLE+metadata guess was 5 ms off for segment 0, 31 ms for
        segment 1). Re-sync every segment by audio.
      - Stitch: OpenCV's panorama stitcher (estimated focal lengths and
        rotations, graph-cut seam, multi-band blend) stitches a single
        frame pair cleanly, near touchline included. A hand-rolled
        homography fitted on field points did worse: turf texture gives
        mostly false matches, and one plane can't align the whole frame.
      - The phones moved relative to each other during that clip (45.7
        to 57.1 deg apart, up to 6 deg within 10 s), so one calibration
        doesn't hold for the whole video. Re-check on the mount; if it
        still drifts, re-estimate the stitch every second or so.
- [ ] Pixel 11 Pro reports a 108.8 deg horizontal field of view but its
      recorded frame is ~104 deg (stitcher's focal estimate); the Pixel
      11's 103.6 deg matches. Check `CameraSelection.horizontalFovDeg`
      (crop or zoom ratio). Processing doesn't depend on it today.
- [ ] Players-only follow on the stitched panorama.
- [ ] Clap test on the mount: confirm audio sync also aligns video (each
      phone's audio-to-video offset in the file is assumed equal).

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

- [ ] CDK's deploy-time helper Lambdas (bucket deployment, bucket
      notifications, auto-delete) log to groups CloudFormation doesn't own,
      with no retention; they outlive the stack. Give them a retention
      policy, or clean them up when a stack is deleted (did this by hand for
      the old `SportsBallVideo` stack, 2026-10-11).

- [ ] CLA text (based on the Apache Individual CLA) and CLA Assistant,
      before the repo goes public. The repo stays local until then.
- [ ] `CLAUDE.md` for the repo: licensing split, API contract, how to run
      each part's tests, deployed stack.
- [ ] Cognito sends verification email from its built-in sender (low daily
      limit). Switch to SES before more than a handful of families use it.
- [ ] `bluetooth_low_energy_android` applies the Kotlin Gradle plugin, which
      a future Flutter release will reject. Track an update or replace it.
- [ ] Flutter has a newer release available; upgrade and re-run all checks.
