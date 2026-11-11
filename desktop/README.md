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

To sign builds with your Apple Development certificate, copy
`macos/Runner/Configs/Signing.example.xcconfig` to `Signing.xcconfig` (git-
ignored) and set your team. Without it the app is signed ad hoc, and each
rebuild looks like a new app to the Keychain, which asks again before
giving it the saved sign-in.

The engine is looked for in Settings, then inside the app
(`Contents/Resources/osb-engine/osb-engine`), then `$OSB_ENGINE`. Build one
with opensportsball-processing's `packaging/mac/build_engine.sh`. To build it
into the app, copy `macos/Runner/Configs/Engine.example.xcconfig` to
`Engine.xcconfig` (git-ignored) and set its folder: `macos/copy_engine.sh`
copies it in at build time (about 1.8 GB the first time, then only what
changed). Without it, as in CI, the app is built without the engine.

Signing in needs a site whose `/config.json` has `desktopClientId` (infra's
`Desktop` Cognito client).

### A real game, shortened

To try a real game from the site without downloading and processing all
of it:

```sh
OSB_MAX_SEGMENTS=4 OSB_MAX_CHUNKS=1 OSB_WORK_FOLDER=/tmp/osb-short \
OSB_ENGINE=/path/to/osb-engine/osb-engine flutter run -d macos
```

`OSB_MAX_SEGMENTS` downloads only the first few segments of each phone
(about 2.5 GB a segment pair) and trims the local manifest to match, so the
engine sees a short but complete recording; `OSB_MAX_CHUNKS` processes only
that many chunks. Use a separate `OSB_WORK_FOLDER`: a shortened game's
results would otherwise sit where the full game's go.

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

## Without the window: `osb`

What the app does before the engine takes over, as a command for a script
or a model working for the user (docs/MAC-APP-PLAN.md, "Using it without
the GUI"). It lives in `../packages/osb_core` (`bin/osb.dart`,
`lib/src/cli.dart`), and every build puts it inside the app
(`macos/build_osb.sh`), where it needs nothing else installed:

```sh
alias osb=/Applications/OpenSportsBall.app/Contents/MacOS/osb
# or from a checkout: cd ../packages/osb_core && dart compile exe bin/osb.dart -o osb

osb status                 # signed in? where games go; the engine it found
osb sign-in                # opens the browser; waits for the person to sign in
osb games                  # the account's games
osb download <game id>     # into the folder the app uses, with a job.json
osb-engine prepare '<that folder>/job.json'
```

Every line it prints is one JSON object with an `event`, as the engine's
are, and `next` names the command that follows. Exit codes: 0 done, 2 a
bad command or a game that isn't there or ready, 3 not signed in, 4 the
server or network failed, 130 stopped. From there the engine is driven as
opensportsball-processing's `docs/ENGINE-AGENTS.md` describes. Run from
inside the app, `osb` names the engine the app carries by its full path
(`status`'s `engine`, and `next` after a download); `$OSB_ENGINE` names
another. Neither is on the PATH yet.

Signing in happens in the person's browser; the command never sees the
password, and keeps its session apart from the app's, in a file only its
owner can read (`$OSB_SESSION_FILE`, else Application
Support/OpenSportsBall/cli-session.json). The site's Desktop sign-in
client must allow its callback (`http://localhost:47161-47163/callback`,
infra's `DESKTOP_CLI_LOGIN_CALLBACKS`): deploy infra before first use.

## Releasing

People install a DMG from the
[GitHub releases](https://github.com/OpenSportsBall/opensportsball/releases)
(`mac-v<version>`). The app then updates itself with
[Sparkle](https://sparkle-project.org): release builds read
`releases/latest/download/appcast.xml` and offer a newer version there.
That link follows the release marked "latest", so a release of anything
else in this repository must not be marked latest. Debug builds, and builds
without the update key, never offer updates.

`tool/release_mac.sh` builds the release with the engine inside and signs
every program and library in the app with the hardened runtime and a
secure timestamp (about 450 in the engine). It makes
`build/release/OpenSportsBall.dmg` (about 800 MB; the same name in every
release, because the website links to the latest release's), notarizes and
staples it, writes `build/release/appcast.xml`, and prints the
`gh release create` command that publishes both. Bump `version:` in
`pubspec.yaml` first: Sparkle compares the build number after the `+`.

It needs, once per release Mac:

- **A Developer ID Application certificate** in the login keychain. Only
  the account holder can create one. In Keychain Access (on recent macOS:
  `open "/System/Library/CoreServices/Applications/Keychain Access.app"`),
  Certificate Assistant → Request a Certificate From a Certificate
  Authority… → Saved to disk; then at developer.apple.com → Certificates →
  "+" → Developer ID Application (G2 Sub-CA), upload that file, and
  double-click the `.cer` it gives back. Check that the certificate and its
  key are both in the **login** keychain (`security find-identity -v -p
  codesigning ~/Library/Keychains/login.keychain-db` lists it); one that
  lands in another keychain, such as `old-login`, makes codesign ask for a
  password that never works. Then let codesign use the key without asking,
  once (it asks for the login password):

  ```sh
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
  ```

  Without the certificate the script stops. `OSB_SIGN_IDENTITY="Apple
  Development: …"` signs a build that only your team's Macs can open, to
  try the script.
- **The update key.** Sparkle's `generate_keys` (built under
  `build/macos/SourcePackages/artifacts/sparkle/Sparkle/bin/` by the first
  build) creates it in the login Keychain and prints its public half:

  ```sh
  build/macos/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account opensportsball-mac
  ```

  Put the public half in `OSB_UPDATE_PUBLIC_KEY` in
  `macos/Runner/Configs/AppInfo.xcconfig`. Back the private half up
  (`generate_keys --account opensportsball-mac -x <file>`, then keep that
  file somewhere safe and off this Mac): installed apps accept only
  updates it signed.
- **A notary key**, an App Store Connect API key, in `OSB_NOTARY_KEY_ID`,
  `OSB_NOTARY_ISSUER` and `OSB_NOTARY_KEY` (the `.p8` file), or a
  `xcrun notarytool store-credentials` profile in `OSB_NOTARY_PROFILE`.
  Notarizing uploads the DMG to Apple and usually takes 5-30 minutes.

### Each release

1. Rebuild the engine if processing changed (opensportsball-processing's
   `packaging/mac/build_engine.sh`) and point `Engine.xcconfig` at it.
2. Bump `version:` in `pubspec.yaml` (the number after `+` must go up),
   merge that to `main`.
3. Run `tool/release_mac.sh` with the notary settings. It ends by printing
   the publish command.
4. Write the release notes: what changed, and, because the engine is AGPL,
   the opensportsball-processing commit it was built from (its `VERSION`
   file, `Contents/Resources/osb-engine/VERSION`) with links to that
   commit's source and to `packaging/mac/build_engine.sh`.
5. Publish with the printed `gh release create … --latest` command, with
   `--target` set to the `main` commit it was built from. Installed apps
   see the new appcast at once, and the website's "Get the Mac app" link
   now gives the new DMG.
6. Check: the release is marked latest,
   `releases/latest/download/appcast.xml` is the new one, and the DMG
   opens on a Mac that hasn't run a development build.

## Tests

```sh
flutter test                         # unit and widget tests
OSB_DEMO_RECORDING=... OSB_ENGINE=... OSB_WORK_FOLDER=... [OSB_E2E_RUN=1 OSB_MAX_CHUNKS=1] \
  flutter test test/e2e_test.dart    # the whole way with the real engine (slow)
OSB_SCREENS_RECORDING=/path/to/prepared/rec OSB_SCREENS_OUT=/tmp/screens \
  flutter test test/screens_test.dart  # the screens as PNGs
```
