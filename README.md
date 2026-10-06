# SportsBallVideo

Open-source, two-phone game recording for youth soccer. Two phones on a
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
              upload manifest complete -> Step Functions
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
| `web/` | Account website | Apache-2.0 |
| `api/` | Lambda API handlers | Apache-2.0 |
| `infra/` | AWS CDK stack | Apache-2.0 |
| `shared/` | Data contracts shared by both sides (upload manifest schema) | Apache-2.0 |
| `processing/` | GPU pipeline: sync, stitch, track, render | **AGPL-3.0-only** |
| `ml/` | Labeling, training, evaluation | **AGPL-3.0-only** |
| `docs/`, `scripts/`, root files | Docs and tooling | Apache-2.0 |

## Licensing

This repository is **split-licensed**. Each top-level directory carries its
own `LICENSE`, and every source file carries an `SPDX-License-Identifier`
header. Read [docs/LICENSING.md](docs/LICENSING.md) before adding a
dependency or moving code between directories. Contributions require
agreeing to the contributor license agreement; see
[CONTRIBUTING.md](CONTRIBUTING.md).
