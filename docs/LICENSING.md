# Licensing rules

OpenSportsBall is two repositories with different licenses:

- **This repository, Apache-2.0:** `app/`, `web/`, `api/`, `infra/`,
  `shared/`, `docs/`, `scripts/`, `.github/`, root files.
- **opensportsball-processing, AGPL-3.0-only:** the processing pipeline
  (`processing/`), including its labelling and model-training tools.

Why: the apps, website and infrastructure stay permissive so anyone can
self-host and ship the mobile app through the app stores (GPL-family
licenses conflict with App Store terms). The processing pipeline, the most
valuable part, is AGPL so a hosted fork has to publish its changes.

## Rules

1. **Every source file starts with an SPDX header:**

   ```
   // SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
   // SPDX-License-Identifier: Apache-2.0
   ```

   Files that can't carry a comment (Markdown, JSON, YAML) are covered by
   `REUSE.toml`. CI runs `reuse lint` and `scripts/check_licenses.py`.

2. **The boundary is one-way.** Code here must never import, vendor or
   link the AGPL processing code. The apps and API talk to processing only
   through data: S3 objects, the upload manifest, the `RecordingReady`
   event, and job status records. AGPL code may use Apache code.

3. **Shared data contracts live in `shared/` (Apache-2.0)**, for example
   `shared/schemas/manifest.schema.json`. This repository owns them. The
   processing repository keeps a pinned copy (its `schemas/`) and checks it
   against this one with `scripts/sync_schema.py`. Change a contract here
   first, bump `schemaVersion` when processing must tell versions apart,
   then re-sync the copy.

4. **No AGPL or GPL dependencies in this repository.** Check a new
   dependency's license before adding it.

5. **Contributor license agreement.** All contributions to both
   repositories require the CLA (see `CONTRIBUTING.md`). It is what lets the
   project offer the processing pipeline under a commercial license
   alongside the AGPL. Rules about detectors and the AGPL hosting
   obligation are in the processing repository's `CONTRIBUTING.md` and
   `README.md`.
