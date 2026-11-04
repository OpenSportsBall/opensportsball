# OpenSportsBall development plan

Goal: an open-source two-phone soccer recorder. Two phones on a dual-phone
mount record the field, the cloud stitches and follows the play, and the
result goes to a configured YouTube account. The backend is as ephemeral as
possible to keep costs low.

## Status (2026-10-06)

- Phase 1 (capture app): built, not yet tested on phones. See
  [TESTING-APPS.md](TESTING-APPS.md).
- Phase 2 (cloud ingest + accounts): deployed to `us-west-2` (stack `OpenSportsBall`, 2026-10-11)
  and verified end to end (link, manifest, multipart upload, ready, hand-off
  event). See [API.md](API.md) and `infra/README.md`. Uploads run while the app is open;
  background upload is still to do.
- Phase 0 (feasibility on real footage): see the
  [opensportsball-processing](https://github.com/OpenSportsBall/opensportsball-processing) repository.

Open work is tracked in [BACKLOG.md](BACKLOG.md).

## Decisions so far

| Decision | Choice | Why |
|---|---|---|
| Apps | One Flutter app with Main / Secondary roles | One codebase and one store listing; any phone can take either role |
| Camera | Native plugin (`app/plugins/dual_camera`) | The stock Flutter `camera` plugin can't lock exposure / white balance / focus, disable stabilization, pick the ultra-wide lens, set bitrate, or segment |
| Phone-to-phone link | BLE | Works iPhone-to-Android with no Wi-Fi on the field; only small control messages |
| Video sync | Audio cross-correlation in the cloud, seeded by a BLE clock estimate | BLE start commands jitter by tens of ms; audio from phones 10 cm apart gives sub-frame accuracy |
| Backend | AWS: S3, Step Functions, Batch on Spot GPU (min 0), API Gateway + Lambda, DynamoDB, Cognito, CDK (TypeScript) | Scales to zero between games; one-command self-host |
| License | Two repos: this one (apps / web / api / infra / shared) Apache-2.0; opensportsball-processing (processing / ml) AGPL-3.0-only; one CLA | See [LICENSING.md](LICENSING.md) |
| Public repo | Private on GitHub ([OpenSportsBall](https://github.com/OpenSportsBall)) for now; public once CLA Assistant and the org's security settings are in place | |

## Open decisions

- Default recording resolution: 4K (better ball detection) or 1080p
  (battery and heat).
- Self-host only, or also a hosted service. Drives how much the YouTube
  quota and audit matter.
- CLA: `CLA.md` (v1.0) is final; CLA Assistant still needs connecting
  before the repos go public.

## Capture

- Main shows a pairing QR code; Secondary scans it and connects over BLE.
- BLE carries: start, stop, heartbeat, battery / storage / thermal status,
  and clock-sync ping/pong.
- Each phone records 5-minute segments with focus and white balance locked
  and stabilization off. Exposure stays automatic by default (light changes
  over a game; processing matches brightness frame by frame), with a
  setting to lock it. A crash loses at most one segment.
- Segments switch files without dropping frames: Camera2 + MediaRecorder
  `setNextOutputFile` on Android, AVAssetWriter rotation on iOS.
- About 35 Mbps 4K HEVC is 20-25 GB per phone per game.
- Upload: S3 multipart through presigned URLs, Wi-Fi only by default.
  Android WorkManager (unmetered constraint); iOS background `URLSession`
  from file.
- Main uploads the manifest (`shared/schemas/manifest.schema.json`); each
  other phone uploads its own segment list, so the phones need not be
  together when they reach Wi-Fi. Processing starts only when every
  phone's segments have arrived.

## Processing (one AWS Batch GPU job, g5/g6.xlarge Spot)

The code lives in the [opensportsball-processing](https://github.com/OpenSportsBall/opensportsball-processing) repository, with its
findings, data layout, test methods and backlog.

1. **Sync:** cross-correlate the audio tracks for the offset; resample both
   variable-frame-rate videos to constant fps on their timestamps.
2. **Calibrate:** the mount is fixed and the field is 30-100 m away, so
   parallax is negligible and one stitch works for the whole game. Sample
   ~50 frames, match features in the overlap (SIFT + RANSAC homography,
   robust average), cylindrical projection, gain compensation, seam blend.
   Left / right order comes from the matches. Output: remap tables.
3. **Pass A:** decode both videos, stitch on the GPU, detect players and
   ball on panorama tiles (the ball is a few pixels wide), write detections.
   Optionally write a low-res full-field panorama.
4. **Path:** offline, so the camera can use future frames. Kalman-filter
   the ball; blend its position (weighted by confidence) with a center of
   play from player positions and motion; smooth over the whole game with
   speed and acceleration limits; zoom follows player spread.
5. **Pass B:** decode again, stitch only the crop region, render a
   perspective-correct 1080p view, encode with NVENC.
6. **Upload:** a Fargate task streams the MP4 from S3 to YouTube with a
   resumable upload (Lambda's 15-minute limit rules it out).

Rough cost per game: $0.50-1.50 Spot GPU, about $0.50 egress to YouTube,
about $1/month raw storage until the lifecycle rule deletes raw footage N
days after a successful render.

## YouTube constraints

- `videos.insert` costs 1,600 of the default 10,000 daily quota units:
  about 6 uploads a day per Google Cloud project.
- API projects that haven't passed Google's audit can only upload
  **private** videos. Self-hosters use their own project and accept
  private, or get audited.
- OAuth with offline access; refresh token encrypted with KMS.
- Default privacy unlisted or private, with a consent note: footage shows
  minors.

## Phases

| Phase | Goal | Exit criteria |
|---|---|---|
| 0. Feasibility spike (1-2 wk) | Record 2-3 real games with stock camera apps on the mount; prototype sync, stitch and tracking in a notebook | A watchable followed video with no apps or cloud |
| 1. Capture app (3-5 wk) | `dual_camera`, BLE pairing and control, segmented recording, live status, Wi-Fi-only upload queue | A full 90-minute game on an iPhone + Android pair with no dropped segments |
| 2. Cloud ingest + accounts (2-3 wk) | CDK stack, Cognito, API, presigned multipart, manifest completeness, website v1 | Both phones' footage in S3; game shows "ready to process" |
| 3. Pipeline v1 (3-4 wk) | Sync, stitch, follow the center of play (players only) | Automatic end-to-end render |
| 4. Ball tracking (4-6 wk, ongoing) | Fine-tune a detector on youth-game footage; Kalman ball track; blended camera target | Measurably better framing on held-out games |
| 5. YouTube (1-2 wk) | OAuth connect, Fargate upload, notifications | Video appears on the configured channel |
| 6. Hardening | Retries, Spot-interruption checkpoints at pass boundaries, cost dashboard, self-host docs | A non-author can deploy it |

Phases 1 and 2 can run in parallel with Phase 3 once Phase 0 works.

## Risks

- Phone heat and battery over 90 minutes of 4K: power bank, dimmed screen,
  1080p fallback, thermal state reported over BLE.
- Mixed phone pairs (different field of view and color): test same-model
  pairs first.
- Ball detection at youth-field distances: Phase 3 ships a players-only
  baseline first.
- iOS background upload of very large files: test early in Phase 1.
- Mount fit: measure which phone models fit the mount and the angle between
  them. Don't use the mount maker's trademark in the project name or
  marketing.
