<!--
SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
SPDX-License-Identifier: Apache-2.0
-->

# OpenSportsBall for Mac

Turns a game the phones recorded into one video that follows the play, on
the user's own Mac, for free (docs/MAC-APP-PLAN.md). The app signs in with
the same account as the phones, downloads a recording's footage, and runs
the processing engine (`osb-engine`, AGPL, in opensportsball-processing) as
a separate program, talking to it only through files and its progress
lines (docs/LICENSING.md; formats in `shared/schemas/engine-*`).

Steps, per game: download → get ready (`osb-engine prepare`) → the checks
(which phone is on the left when the views can't be stitched, the pitch,
the kit groups) → process overnight (`osb-engine run`) → watch. Where a
game stands comes from its folder and `osb-engine status`, so quitting or
a reboot loses nothing.

The non-Flutter parts (sign-in, the API, the download, the engine driver)
are in `../packages/osb_core`, tested with `dart test` there.

## Run it

```sh
flutter run -d macos
```

The engine is looked for in Settings, then inside the app
(`Contents/Resources/osb-engine/osb-engine`), then `$OSB_ENGINE`. Build one
with opensportsball-processing's `packaging/mac/build_engine.sh`.

Signing in needs a site whose `/config.json` has `desktopClientId` (infra's
`Desktop` Cognito client).

### Without a server

`OSB_DEMO_RECORDING` serves a recording already on this Mac (its merged
`manifest.json` and segments, as `footagestore.py fetch` leaves it) through
a stand-in API and footage server, and skips sign-in:

```sh
OSB_DEMO_RECORDING=/path/to/rec OSB_DEMO_SEGMENTS=4 OSB_ENGINE=/path/to/osb-engine/osb-engine \
OSB_WORK_FOLDER=/tmp/osb-demo OSB_MAX_CHUNKS=1 flutter run -d macos
```

`OSB_DEMO_SEGMENTS` keeps the first few segments per phone; `OSB_MAX_CHUNKS`
processes only that many chunks.

## Tests

```sh
flutter test                         # unit and widget tests
OSB_DEMO_RECORDING=... OSB_ENGINE=... OSB_WORK_FOLDER=... [OSB_E2E_RUN=1 OSB_MAX_CHUNKS=1] \
  flutter test test/e2e_test.dart    # the whole way with the real engine (slow)
OSB_SCREENS_RECORDING=/path/to/prepared/rec OSB_SCREENS_OUT=/tmp/screens \
  flutter test test/screens_test.dart  # the screens as PNGs
```
