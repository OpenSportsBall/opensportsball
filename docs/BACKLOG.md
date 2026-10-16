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
- [ ] First real website sign-up (Cognito), link Main (it gives Secondary
      a recording grant), upload a recording on Wi-Fi, game reaches Ready.
      Also pair with a Secondary on another account, and on none.

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

- [ ] Carry the `processing/spikes/phase0.py` findings into the
      pipeline. From a 5-minute handheld field clip (2026-10-12) and a
      97.5-minute night game on a fixed mount (2026-10-14, recording
      `78618588`, 21 segments per phone, run locally off the phones):
      - Audio sync locks in every segment of the game (most 4 s windows
        clean). Clock drift is a steady -9 ppm (~50 ms per game, ~2.5 ms
        per 5-minute segment), so one offset per segment is enough.
      - Re-sync every segment by audio. The offset jumps by up to 390 ms
        at segment switches (the phones lose different amounts), and
        `startedAtDeviceMs` doesn't show it: BLE+metadata was 10 ms off
        for segment 0 and 309 ms off by segment 20.
      - Stitch: OpenCV's panorama stitcher (estimated focal lengths and
        rotations, graph-cut seam, multi-band blend). One calibration from
        segment 0 held for the whole mounted game: overlap points moved
        ~3 px median at 960 px wide in every segment, the same as the
        measurement noise within one segment. The handheld clip drifted
        (45-57 deg apart), so the pipeline needs a rigid mount or a
        periodic re-estimate. Single-pair estimates of the angle are
        noisy at night (78.8-86.8 deg); compare homographies instead.
      - A homography fitted on field points did worse than the stitcher:
        turf texture gives mostly false matches.
      - 97.5 min of 4K on battery: thermal nominal throughout; battery
        100 to 74% (Pixel 11) and 55% (11 Pro); ~24 GB per phone.
- [ ] Pixel 11 Pro reports a 108.8 deg horizontal field of view but its
      recorded frame is ~104 deg (stitcher's focal estimate); the Pixel
      11's 103.6 deg matches. Check `CameraSelection.horizontalFovDeg`
      (crop or zoom ratio). Processing doesn't depend on it today.
- [ ] Players-only follow: `processing/spikes/follow.py` renders a 1080p
      virtual camera straight from both 4K sources. Cameras refined at
      1920 px (median error 11 to 4 px at 4K); each pixel comes from one
      phone along a per-frame seam that avoids players, since the phones
      never capture the same instant and blending doubled moving players;
      two-band blend hides the exposure step. Warping and blending run on
      the GPU (`gpu.py`, PyTorch: MPS locally, CUDA in the cloud), NV12 from
      hardware decode to hardware encode; 20 s of video in 64 s on an
      M-series Mac. Still to do: cross segment boundaries.
- [ ] Follow cam aim, judged by eye on 2 minutes of the night game
      (segment 9, 60-180 s; 2026-10-15). Best so far: "A",
      `follow.py ... play goalkick,goalframe,unsure` (hotspot + goal kicks
      + goal in frame + zoom out when unsure): the only version that
      catches every key moment in the clip, but zoomed out at times
      (median 55 deg). Runner-up: `play goalframe`. All tuned on this one
      clip; check another stretch of the game. What each step fixed:
      - Speed-weighted players beat the median of all players (caught a
        quick counter; in play.py's test, ball in a 60 deg view 100% vs
        66%), but an average of 3-6 runners jumps between groups.
      - Hotspot of running (pooled +-0.5 s, weighted by speed, sticky:
        another spot must be 50% stronger for 0.7 s): followed the attack
        to the left goal; aim jumps > 40 deg/s dropped 435 -> 73 frames.
        Needed linear (not squared) speed weights and 0.5 s position
        smoothing: far-side jitter read as running.
      - Aim only from people inside the lines; spots by a touchline
        occupied >= 10% of the time (bench, subs) are ignored.
      - Lull hold: <= 1 runner for 1 s keeps the aim from just before.
      - goalframe: >= 4 players within 20 m of a detected goal while the
        hotspot is elsewhere: frame both and the goal mouth (<= 75 deg).
        Only worked once goals were detected (pitch.py goals): with the
        model's goal lines it framed the wrong place at the right end.
      - goalkick: a lone near-still player in/near a penalty area soon
        after play was at that end: frame taker and group, held as a
        state until 3 players run for 0.5 s (max 12 s). A keeper 50 m away
        is tracked only on and off, so the pattern is judged over +-1 s.
      - unsure: <= 1 runner near the hotspot keeps the view >= 55 deg,
        <= 2 >= 42 deg (a quick clearance leaves the players behind).
      - lead (aim 1 s ahead): no clear gain in this clip.
      - Hotspot weights, on `play goalframe` (2026-10-15): `nowalk`
        (players under 2 m/s weigh nothing) frames tighter (median 30 vs
        36 deg), goalframe fires ~20% less, and the aim moves elsewhere
        for a few seconds (0:29, 0:42, 0:57); `fastboost` (3x the slope
        above 4 m/s) changes almost nothing: fast runners already
        dominated and the switch rule damps them. Neither adopted.
      - ball (`ballclip.py` candidates from the fine-tuned detector at
        10 fps, `ball.py`'s chain, aim at the ball where tracked >= 0.5 s,
        goalframe and lull hold off there): on `play goalframe` it followed
        the attack to the left goal at :44 with the goal mouth in view,
        but the ball was tracked only 39% of the clip (none after 1:34),
        so it missed the 1:55 goal kick. Next: A + ball (the ball replaces
        unsure's widening where it's known), motion candidates and a
        better tracker to fill the gaps.
      Not solved without the ball: a long clearance until players react.
- [ ] Follow-cam evaluation set (2026-10-16): `playeval.py` builds a
      full-resolution panorama at chosen moments; the page in `evalpage/`
      records a reviewed "must-see" box per moment (panorama degrees);
      `playbench.py` plans every variant from cached player detections
      (seconds per clip) and scores it: moments captured (>= 98% of the
      box in view) and view width. 13 reviewed moments on two 2-minute
      clips (segment 9 from 60 s, segment 3 from 225 s, crossing into 4).
      Note the earlier renders' paths were ~0.7 s off the video (decoder
      frame repeat after a seek, fixed in frame_stream), so judgements of
      those renders don't line up with these scores. Results:
      - A (goalkick,goalframe,unsure): 4/13, median width 54 deg. Misses
        are aim, not width: the hotspot stays on the chasing pack while
        a lone runner has the ball, or the shot happens at the goal ahead
        of the pack; a throw-in taker at the bench is filtered out.
      - Hotspot tweaks without the ball (weak, nowalk, allnear, flow,
        lone, goalin, gk2, bigger bandwidth, no lull): none beat 4/13.
      - A + ball (fine-tuned detector + chain, 10 fps): 8/13 at 54 deg.
        A + ball + goalin (goal mouth kept in frame when the hotspot is
        within 30 m of a goal): 9/13, mean coverage 85%, same width:
        the best principled result. + nowalk (2 m/s) reaches 10/13 but
        wider (68 deg) and mostly by accident (a wide goal-kick frame).
      - Still missed: a goal kick where the ball sits in the keeper's
        hands (seg 9, 70 s: tracker loses it, camera lags), a throw-in
        taken from the bench spot by the camera (seg 3, 105 s: the taker
        is 0.1 m outside the line in a loiter cell), and the clip's first
        seconds (seg 3, 2.5 s: a lull at frame 0; not a full-game issue).
      Next: ball coverage (tracked 23-39% of a clip; motion candidates,
      better tracker), a restart rule for takers in loiter cells, more
      labelled moments from other stretches before tuning further.
- [ ] Pitch map (`pitch.py`): background median, white-paint mask, fit
      of camera position/height, pitch rotation, ground tilt, length and
      width, plus a smooth vertical-angle correction (`warpDeg`, what one
      flat pitch and the camera model can't explain). Goals (`pitch.py
      footage/rec3 goals`, once per game): goal-shaped white structures
      near each end are candidates; each left/right pair is tried by
      refitting so they stand mid goal line; the pair that keeps both
      ends' goal line and 6/18-yard boxes on the paint wins (stored goals
      and other pitches' fail). The goals then correct the map: the right
      end was ~20 m off before. Night game: 109.3 x 60.5 m, camera 2.7 m
      up, goals 7.6 and 7.4 x 2.44 m. Still one-off parts:
      - The starting pose is hand-read from the panorama. Automate it
        (centre circle ellipse + halfway line give distance and height),
        with a tap-two-points fallback in the app (centre spot, a corner).
      - Assumes a regulation layout and full-size goals; youth and
        small-sided pitches need a pitch type or more free sizes.
      - Thresholds tuned on one game; test other venues and daylight.
      - Goals moved mid-game (portable) would need a per-segment re-check.
      Regression test: `processing/tests/test_pitch_regression.py` reruns
      the whole mapping on saved background panoramas and checks goals,
      size, camera and 15 key points (<= 0.1 deg) against results checked
      by eye. Fixtures hold footage, so they stay out of git
      (`footage/fixtures/pitch/<name>`, made by `pitch.py <rec> fixture
      <dir>`; back them up privately). One so far: the night game.
- [ ] Ball labelling: `labelset.py` (300 random moments, RF-DETR
      suggestions, stitched panoramas; unlabelled frames turned into
      both-phone moments) and `label/server.py` (local page: panorama
      plus a magnifier per phone; every ball marked, the match ball
      flagged; repeat figments hidden after the first few labels).
      408 of 409 frames labelled (183 with the match ball).
- [ ] Ball detection (night game, 2026-10-15):
      - Off-the-shelf RF-DETR "sports ball" on 4K tiles: 58% of match
        balls at conf >= 0.2 with 2.1 wrong suggestions per frame.
      - Motion (`motion.py`: difference from the median of +-1 s and from
        the neighbouring frames, blobs of ball size for the distance):
        55% of match balls but ~120 candidates per frame, and ranking by
        contrast is poor (top 10: 6%). Detector + motion together: 77%.
        Decode natively (`-fps_mode passthrough`): ffmpeg's frame-rate
        filter repeats the first frame after a seek, hiding all motion.
      - Fine-tuned RF-DETR Medium (`balldata.py` 640 px COCO tiles with
        hard negatives, `balltrain.py`, batch 2 x 8 accumulation on mps,
        ~7 min per epoch, early stop at 26, best epoch 18; mAP50 0.64).
        On held-back moments (`ballcompare.py`, 42 match balls): 76% of
        match balls at conf >= 0.1 with 1.1 wrong per frame (stock: 69%
        with 10.5); the top suggestion is the match ball 69% of the time
        (stock 40%). On training moments 96%: overfit to this game, so
        label a second game before training more.
      - Next: the tuned detector as a judge of motion candidates, and a
        tracker with ball physics (ground rolls, lofted balls projecting
        long).
- [ ] Follow cam speed, further ideas (a full game is ~2.5 h locally
      today, half in each pass):
      - Pass A (detection, seam) at 10 fps, reusing results for the frames
        between: about a third of its cost. Check that the seam's player
        margin still covers fast play near the overlap.
      - Pass A's panorama: scale on the GPU in the decoder (`scale_vt`)
        instead of in software; download it smaller (luma only, or half
        size) or move background subtraction onto the GPU.
      - Seam search in compiled code (numba) or on the GPU instead of a
        Python loop over rows.
      - Fixed mount: precompute a direction -> source pixel lookup once per
        game, so per-frame geometry is a lookup into it.
      - Fuse the render's elementwise steps (`torch.compile`, or a custom
        Metal/CUDA kernel); render in fp16 throughout.
      - Run passes A and B concurrently (B lagging A by the path's
        smoothing window), so decode and GPU work overlap across passes.
      - In the cloud: NVDEC/NVENC and CUDA on the Batch GPU instance, and
        split a game across instances by segment.
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
