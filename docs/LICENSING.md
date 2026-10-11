# Licensing rules

OpenSportsBall is split-licensed:

- **Apache-2.0:** `app/`, `web/`, `api/`, `infra/`, `shared/`, `docs/`,
  `scripts/`, `.github/`, root files.
- **AGPL-3.0-only:** `processing/`, `ml/`.

Why: the apps, website and infrastructure stay permissive so anyone can
self-host and ship the mobile app through the app stores (GPL-family
licenses conflict with App Store terms). The processing pipeline, the most
valuable part, is AGPL so a hosted fork has to publish its changes.

## Rules

1. **Every source file starts with an SPDX header** matching its directory:

   ```
   // SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
   // SPDX-License-Identifier: Apache-2.0
   ```

   Files that can't carry a comment (Markdown, JSON, YAML) are covered by
   `REUSE.toml`. CI runs `reuse lint` and `scripts/check_licenses.py`.

2. **The boundary is one-way.** Apache code must never import, vendor or
   link AGPL code. The apps and API talk to `processing/` only through data:
   S3 objects, the upload manifest, and job status records. AGPL code may
   use Apache code.

3. **Shared data contracts live in `shared/` (Apache-2.0)**, for example
   `shared/schemas/manifest.schema.json`. Both sides read them; neither side
   owns them.

4. **No AGPL or GPL dependencies outside `processing/` and `ml/`.** Check a
   new dependency's license before adding it.

5. **The detector sits behind an interface**
   (`processing/src/osb_processing/detectors/base.py`). Ultralytics YOLO is
   AGPL-3.0, which is compatible with `processing/`, but while it is a
   dependency the project cannot offer `processing/` under a commercial
   license without also buying an Ultralytics enterprise license. Keeping an
   Apache-2.0 detector (RF-DETR) working preserves that option.

6. **Hosting obligation.** Anyone running a modified `processing/` as a
   network service, including the maintainers, must offer users that
   modified source (AGPL section 13). Don't run private modifications in
   production.

7. **Contributor license agreement.** All contributions require the CLA
   (see `CONTRIBUTING.md`). It is what lets the project offer `processing/`
   under a commercial license alongside the AGPL. Do not merge outside
   contributions to `processing/` or `ml/` without a signed CLA.
