# OpenSportsBall

Open-source, two-phone game recording for field sports. Two phones on a
dual-phone mount record the full field; the cloud stitches the two videos
into one panorama, follows the play with a virtual camera, and uploads the
result to YouTube.

> Status: pre-alpha scaffold. Nothing works end to end yet. See
> [docs/PLAN.md](docs/PLAN.md) for the roadmap.

## How it works

```
[Main phone] --BLE control + clock sync--> [Secondary phone]
     |  record 5-min segments, exposure / focus / white balance locked
     +-- both phones upload to S3 in the background (Wi-Fi only by default)
                         |
        upload complete -> "Process in the cloud" on the website
                         |
   AWS Batch on Spot GPU (scales to zero): sync -> stitch -> track -> render
                         |
            upload task -> YouTube   .   notify "your video is ready"

Website (static, S3 + CloudFront) -- API Gateway + Lambda + DynamoDB + Cognito
```

## Repository layout

| Path | What | License |
|---|---|---|
| `app/` | Flutter app (one app, Main / Secondary roles) | Apache-2.0 |
| `app/plugins/dual_camera/` | Native camera plugin (CameraX / AVFoundation) | Apache-2.0 |
| `desktop/` | Mac app (Flutter): processes a game on the user's own Mac with the engine | Apache-2.0 |
| `packages/osb_core/` | Plain Dart shared by the apps: sign-in, API, footage download, driving the engine | Apache-2.0 |
| `web/` | Account website | Apache-2.0 |
| `api/` | Lambda API handlers | Apache-2.0 |
| `infra/` | AWS CDK stack | Apache-2.0 |
| `shared/` | Data contracts shared by both sides (upload manifest; the processing engine's job, questions, answers, progress events, label sets and contributions) | Apache-2.0 |
| `docs/`, `scripts/`, root files | Docs and tooling | Apache-2.0 |

## Licensing

This repository is **Apache-2.0**. Each top-level directory carries its own
`LICENSE`, and every source file carries an `SPDX-License-Identifier`
header.

The processing pipeline (sync, stitch, track, render) and the ML tooling
live in a separate repository,
**[opensportsball-processing](https://github.com/OpenSportsBall/opensportsball-processing)**, under
**AGPL-3.0-only**. The two share no code, only data: the upload manifest
(`shared/schemas/`), S3 objects and the `RecordingReady` event. Read
[docs/LICENSING.md](docs/LICENSING.md) before adding a dependency. Contributions require
agreeing to the contributor license agreement; see
[CONTRIBUTING.md](CONTRIBUTING.md).
