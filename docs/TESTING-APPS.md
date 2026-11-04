# Testing the capture app on phones

The app is not in any store yet. Install it from the Mac over USB, send
iPhone builds to testers through TestFlight, or Android builds through a
Google Play test track (below).

## Install

Build in **release** mode for anything involving the camera. Debug builds
are much slower and can drop frames.

### iPhone

1. On the iPhone: Settings → Privacy & Security → **Developer Mode** → on
   (the phone restarts).
2. Open `app/ios/Runner.xcworkspace` in Xcode → Runner target → **Signing &
   Capabilities** → pick your Apple ID as the team. A free Apple ID works;
   its installs expire after 7 days.
3. Plug in the phone, then:

   ```
   cd app
   flutter devices
   flutter run --release -d <iphone id>
   ```

4. First launch only: Settings → General → VPN & Device Management → trust
   your developer certificate.

### Android

1. Settings → About phone → tap **Build number** 7 times, then Developer
   options → **USB debugging** → on.
2. Plug in, accept the prompt on the phone, then:

   ```
   cd app
   flutter run --release -d <android id>
   ```

### TestFlight (iPhone, no cable)

Ships a build to testers through App Store Connect. Each build expires
90 days after upload. The app needs iOS 17 or newer; ask testers for an
iPhone 12 or newer (the ultra-wide lens arrived with the 11, and the 12 is
the oldest that stays cool through a full game).

1. Bump the build number in `app/pubspec.yaml`: the `+N` in
   `version: 0.1.0+1` must increase for every upload (App Store Connect
   rejects a build number it has already seen).
2. Build the archive. CocoaPods lives in `/opt/homebrew/bin`, which must be
   on `PATH`:

   ```
   cd app
   PATH=/opt/homebrew/bin:$PATH flutter build ipa --release
   ```

   The output is `app/build/ios/ipa/opensportsball.ipa`.
3. Validate, then upload, with an App Store Connect API key. The key file
   `~/private_keys/AuthKey_<key id>.p8` is never committed; `altool` finds
   it in `~/private_keys` by key ID.

   ```
   xcrun altool --validate-app --type ios -f build/ios/ipa/opensportsball.ipa \
     --apiKey <key id> --apiIssuer <issuer id>
   xcrun altool --upload-app --type ios -f build/ios/ipa/opensportsball.ipa \
     --apiKey <key id> --apiIssuer <issuer id>
   ```

4. App Store Connect → the app → **TestFlight**. The build appears after
   a few minutes of processing (an email arrives when it is ready). Then
   add testers:
   - **Internal:** members of the App Store Connect team, available as
     soon as processing finishes.
   - **External:** anyone by email or a public link; the first build of
     each version goes through a short Beta App Review first.
5. Testers install the **TestFlight** app from the App Store and accept
   the invite. Upload a new build before the 90 days run out.

One-time setup:

- Apple Developer Program membership; a free Apple ID cannot upload.
- `app/ios/Runner.xcworkspace` in Xcode → Runner target → **Signing &
  Capabilities** → set the team (automatic signing).
- Create the app record in App Store Connect (bundle ID
  `dev.opensportsball.opensportsball`) before the first upload; `altool`
  fails until it exists.
- Create an API key under Users and Access → Integrations → App Store
  Connect API; download the `.p8` (only possible once) into
  `~/private_keys/` and note the key ID and issuer ID.
- A team with no iPhone registered fails the archive with "no devices".
  In Xcode, pick the **My Mac (Designed for iPad)** run destination once,
  which registers the Mac as a device, then build again.

### Google Play (Android, no cable)

Play only takes app bundles signed with the **upload key**. Release
builds without it fall back to the debug key (fine for `flutter run
--release`), but `flutter build appbundle` stops with an error.

1. Bump the build number in `app/pubspec.yaml`, as for TestFlight; Play
   rejects a version code it has already seen.
2. Build:

   ```
   cd app
   flutter build appbundle --release
   ```

   The output is `app/build/app/outputs/bundle/release/app-release.aab`.
3. Play Console → the app → **Test and release** → a track (internal,
   closed, or production) → **Create new release** → upload the `.aab`.

One-time setup:

- Create the upload keystore, outside the repository, and back it up
  (losing it means asking Google to reset the upload key). `keytool` comes
  with Android Studio:

  ```
  "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" -genkeypair -v \
    -keystore ~/private_keys/opensportsball-upload.jks -keyalg RSA -keysize 2048 \
    -validity 10000 -alias upload
  ```

- Create `app/android/key.properties` (git ignores it):

  ```
  storeFile=/Users/<you>/private_keys/opensportsball-upload.jks
  storePassword=<password>
  keyAlias=upload
  keyPassword=<password>
  ```

- Leave **Play App Signing** on when creating the app: Google holds the
  real signing key, and the key above only proves uploads are yours.
- A personal developer account must run a closed test with at least 12
  testers for 14 days before it can publish to production.

## Getting recordings off the phones

- **In the app:** Recordings → expand a recording → Share all (AirDrop,
  Files, Drive, ...).
- **iPhone over USB:** Finder → the phone → Files → OpenSportsBall →
  `recordings/`.
- **Android over USB:** `Android/data/dev.opensportsball.opensportsball/files/recordings/`
  (on a Mac, use Android File Transfer or `adb pull`).

Each recording folder has the video segments, `recording.json`,
`power.csv`, and on the Main phone a `manifest.json` once both phones'
segments are known.

`power.csv` has one row at start, one a minute while recording, and one at
the end: battery %, charging, thermal state (`nominal` / `fair` / `serious`
/ `critical`), free storage in MB, and a note (`start`, `stop`, or why
recording ended). Use it to see how long a phone lasts at a given
resolution and when heat sets in.

## Bench tests (no game needed)

Set **Segment length → 1 min** in Settings first so segment rollover happens
quickly.

1. **One phone.** Main → Start → "Record alone". Record 3-4 minutes, stop.
   Recordings should show 4 segments. Copy them off and check there is no
   gap between files (see "Checking files" below).
2. **Pairing.** Phone A: Main. Phone B: Secondary → scan A's QR code. A
   should show the Secondary's battery, storage and temperature within a few
   seconds, plus a clock offset.
3. **Paired recording.** Record 5 minutes, stop on Main. Main's recording
   section should reach "Manifest: ready".
4. **Dropped link.** While recording, turn Bluetooth off on the Secondary
   for 30 seconds, then back on. The Secondary must keep recording and show
   "Lost contact"; it should reconnect by itself. Stop on Main; the manifest
   should still complete.
5. **Out of range.** While recording, walk the Secondary far away, stop on
   Main, then press "Stop on this phone" on the Secondary and walk back.
   The manifest should complete once they reconnect (keep the Main screen
   open).
6. **Interruption.** Call one phone while it records. It should stop,
   save the segment in progress, and the Main phone should show an error.
7. **Mixed pair.** Repeat 2-3 with one iPhone and one Android phone.
8. **Dark screen.** Start a paired recording and wait 15 seconds: both
   screens should go black at minimum brightness with a dim "REC" line.
   Tap: the normal screen returns, and that tap must not press anything.
   It darkens again 15 seconds after the last touch. Stopping restores the
   screen. Check the recorded file has no gap or glitch where the screen
   went dark (only the preview pauses).
9. **No signal at the field.** With Main linked, open the app once on
   Wi-Fi (Main keeps three offline permissions in stock). Then turn on
   airplane mode on both phones and turn Bluetooth back on. Pair, record
   a minute, stop. Main shows the Secondary's footage going "to this
   phone's account (confirmed once online)". Turn airplane mode off on
   both: each uploads, and the game reaches Ready on the website. If Main
   says "no offline permissions left", it hasn't been online since it was
   linked or since its last offline games.
10. **Full length.** 90 minutes at 4K on power banks, phones on the mount in
   the sun if possible. Watch temperature and storage on the Main screen.
   For a battery run, start at 100% without a power bank and record until
   the phone stops; `power.csv` gives the drain per hour and when the
   thermal state rose.

## Checking files

With `ffprobe` (`brew install ffmpeg`):

```
ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate,sample_rate,channels \
  -show_entries format=duration,bit_rate -of compact <file>.mp4
```

Expect `hevc` (or `h264` on older phones), 3840x2160 (or 1920x1080),
30/1 fps, `aac` at 48000 Hz. For gaps: the durations of consecutive
segments should add up to the wall-clock recording time, and joining them
with the ffmpeg concat demuxer should play smoothly with no click at the
joins:

```
printf "file '%s'\n" *_0*.mp4 > list.txt
ffmpeg -f concat -safe 0 -i list.txt -c copy joined.mp4
```

## Platform checklists

Things only a real phone can confirm, from the camera implementations.

### iOS

- Permission prompts show the camera, microphone and Bluetooth reasons;
  denying the microphone stops the camera opening.
- Ultra-wide is used where the phone has one, with a field of view around
  100-110°; phones without one fall back to wide.
- Recording and preview are upright and the preview aspect ratio is right.
- Panning bright to dark: white balance and focus stay fixed; exposure only
  stays fixed with "Lock exposure" on. Distant objects are sharp.
- **Settle and focus sweep:** start recording with the phone in your hand,
  walk around, then put it on the tripod. About 5 s after it stops moving
  the picture hunts focus for a few seconds (the sweep) and settles sharp.
  Raise the tripod: it does it again once still. Share the recording's
  `report.json` (or `manifest.json` on Main): `settingsLocks` should show
  one `settled` lock per placement, `focus.method` `sweep`, and a `sweep`
  list whose sharpness peaks somewhere short of the far end. The far
  floodlights and goals must be sharp, not just the near grass.
- Shaking the phone gently: the image must not "float" (would mean
  electronic stabilization is on). Optical stabilization can't be turned
  off on iOS.
- Killing the app mid-segment (Xcode stop) leaves a playable partial file up
  to its last ~10 s, and earlier segments intact. It can also leave one
  extra empty file for the next segment.
- Calls, backgrounding and opening the Camera app each stop recording and
  save the segment in progress; the preview comes back afterwards.
- Under 500 MB free, recording stops with a storage error.
- The screen does not auto-lock while the app is recording.
- 90 minutes at 4K: watch for stutter in the preview and the temperature.

### Android

- Permission prompts for camera, microphone and nearby devices; denying the
  camera or microphone stops the camera opening.
- **Segment switches:** Android can only switch files on a size limit, so
  segments run roughly the set length (often a bit over) and a few frames
  may drop at each switch. Record 5 minutes of a running stopwatch with
  1-minute segments and count frames either side of each boundary
  (`ffprobe -show_frames`). Expect at most a few per boundary; note how
  many.
- Recording plays upright (check the rotation tag with ffprobe), and the
  preview is upright, not stretched, and matches the recorded framing.
- Ultra-wide is chosen on a Pixel (zoom below 1.0 on the main camera) and
  on a Samsung (separate ultra-wide camera). `adb logcat -s DualCamera`
  shows the "open camera=... zoom=..." line. Field of view about 100-120°
  for ultra-wide.
- `ffprobe` shows `hevc`, 3840x2160, constant 30 fps (`r_frame_rate` equals
  `avg_frame_rate`), AAC 48000 Hz mono.
- Tapping the mount makes the image shake, not float (stabilization off).
- After the lock, white balance and focus don't change when panning;
  exposure only stays fixed with "Lock exposure" on.
- **Settle:** start recording off the tripod, then mount it; `settingsLocks`
  in `manifest.json` / `report.json` gets a `settled` lock about 5 s after
  it stops moving (`focus.method` `infinity`), and another after raising
  the tripod. Shaking it in your hand or lying it flat never locks it.
- Film a screen showing epoch milliseconds to check the first frame's
  start time (expect about one frame of error).
- Another camera app or a call ends the recording, saves the last segment,
  and the file plays.
- Start, stop, start again without leaving the screen works.
- Under 500 MB free, recording stops with a storage error after the last
  segment is saved.
- Recording needs the app in the foreground with the screen on; Android
  takes the camera away from background apps.
