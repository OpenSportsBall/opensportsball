# dual_camera platform channel contract

The Dart side (`lib/dual_camera.dart`) and the two native sides
(`android/.../DualCameraPlugin.kt`, `ios/.../DualCameraPlugin.swift`) must
agree on exactly this. Change all three together.

- MethodChannel: `dev.opensportsball/dual_camera`
- EventChannel: `dev.opensportsball/dual_camera/events`

All arguments and results are maps with the keys below. Times are
milliseconds. `deviceMs` means wall-clock milliseconds since the Unix epoch
on this phone (`System.currentTimeMillis()` / `Date().timeIntervalSince1970
* 1000`).

Errors are `PlatformException`s (`FlutterError` on iOS) with one of these
codes: `permission_denied`, `camera_unavailable`, `unsupported_config`,
`not_open`, `already_recording`, `not_recording`, `io_error`, `internal`.

## Methods

| Method | Args | Result |
|---|---|---|
| `checkPermissions` | none | `{camera: bool, microphone: bool}` |
| `requestPermissions` | none | `{camera: bool, microphone: bool}` (prompts if not yet decided) |
| `requestBluetoothPermission` | none | `bool`: granted. Android asks for Nearby devices (12+) or location (older) if needed; iOS returns `true` (the system asks on first Bluetooth use). Call this before creating any Bluetooth manager. |
| `availableLenses` | none | `List<String>` of back lenses present: `"ultrawide"`, `"wide"` |
| `open` | see below | see below. Opens the camera and starts the preview. |
| `lockSettings` | `{sweepFocus: bool}` | `{exposureLocked: bool, whiteBalanceLocked: bool, focusLocked: bool, focus: {method: String, lensPosition: double?, autofocusLensPosition: double?, sweep: [{lensPosition: double, sharpness: double}]?}}`. Allowed while recording. See Locking below. |
| `startRecording` | `{directory: String, filePrefix: String, uprightRotationDeg: int}` | `{startedAtDeviceMs: int}`. `uprightRotationDeg` (0/90/180/270 clockwise, default 0) is added to the files' display rotation (Android orientation hint, iOS track transform) so a phone mounted upside down plays upright; pixels are not rotated. |
| `stopRecording` | none | `{}`. Returns only after the last segment is finalized and its `segment` event has been sent. |
| `status` | none | `{batteryPercent: int, charging: bool, freeStorageBytes: int, thermalState: String, recording: bool}` |
| `orientation` | none | `{x: double, y: double, z: double}` or `null`: which way is up, as a unit vector in the recorded picture's axes (x to its right, y to its top, z out of the screen; the back camera looks along -z), from gravity averaged over up to a second. `null` if the phone has no usable sensor. A phone mounted upside down gives `y` near -1. |
| `motion` | none | `{samples: int, up: {x, y, z}?, maxRotationDegPerS: double?, maxAccelerationG: double?}`: how the phone moved since the previous call. `up` is gravity averaged over the window, in the same axes as `orientation`; `maxRotationDegPerS` the fastest gyroscope rate; `maxAccelerationG` the largest acceleration apart from gravity. The first call starts the sensors and returns `{samples: 0}`; a field is missing without the sensor for it. |
| `stopMotion` | none | `null`. Stops the sensors `motion` started (`close` also does). |
| `setKeepScreenOn` | `{on: bool}` | `null` |
| `setScreenBrightness` | `{level: double?}` | `null`. 0..1 overrides the screen brightness while the app is in front; `null` hands it back to the system. iOS restores the user's level when the app leaves the foreground. |
| `setPreviewPaused` | `{paused: bool}` | `null`. Stops (or resumes) drawing preview frames; the camera and any recording keep running. |
| `close` | none | `null`. Stops recording first if needed (finalizing segments), releases the camera and the preview texture. |

`thermalState` is one of `nominal`, `fair`, `serious`, `critical`.

### `open`

Args:

```
{
  width: int, height: int,        // requested, landscape (e.g. 3840 x 2160)
  fps: int,                       // requested, e.g. 30
  codec: "hevc" | "h264",
  bitrateBps: int,
  lens: "ultrawide" | "wide",
  segmentDurationMs: int,         // e.g. 300000
  lockExposure: bool              // whether lockSettings also locks exposure
}
```

Result:

```
{
  textureId: int,                 // Flutter texture showing the preview
  previewWidth: int, previewHeight: int,
  width: int, height: int,        // actual recording size
  fps: int,                       // actual
  codec: "hevc" | "h264",         // actual (fall back to h264 if hevc is unsupported)
  lens: "ultrawide" | "wide",     // actual (fall back to wide if no ultrawide)
  horizontalFovDeg: double?       // recorded horizontal field of view, if known
}
```

If the requested size / fps / codec / lens is unsupported, fall back to the
closest supported option and report what is actually used. Only throw
`unsupported_config` if nothing usable exists.

## Events

Each event is a map with a `type`:

```
{type: "segment", index: int, path: String, bytes: int,
 startedAtDeviceMs: int, durationMs: int}
{type: "error", code: String, message: String, fatal: bool}
{type: "interrupted", reason: String}
```

- `segment` is sent once per file, only after the file is fully written and
  closed. `index` starts at 0 for each recording.
- `fatal: true` means recording has stopped (all finished segments are
  already reported).
- `interrupted` covers the OS taking the camera away (phone call, app
  backgrounded, another app, thermal shutdown). Recording is stopped and
  the in-progress segment finalized and reported if possible.

## Recording requirements

1. **Orientation.** The app is locked to one landscape orientation. Record
   upright relative to the interface orientation at the time `open` is
   called, and make the preview match.
2. **Stabilization off.** Video stabilization (electronic and, where
   controllable, optical) must be off. Stitching assumes a fixed image.
3. **Lens.** `ultrawide` means the widest back camera. On Android use the
   physical ultra-wide camera, or a logical camera at its minimum
   `CONTROL_ZOOM_RATIO` when that is below 1.0.
4. **Locking.** `lockSettings` meters once (auto exposure / white balance /
   focus converge first), then locks white balance and focus, and
   exposure only when `lockExposure` was true. Otherwise exposure stays
   automatic. Focus, reported as `focus.method`:
   - Android: `infinity` (`LENS_FOCUS_DISTANCE` 0, which Camera2 defines
     as infinity), `autofocus` (AF held where it settled, if manual focus
     is unsupported), `fixed` or `none`.
   - iOS lens positions are not distances, and 1.0 (the far end of travel)
     is past infinity on some lenses. Without `sweepFocus`: `autofocus`,
     locked where AF settled. With it: `sweep`, stepping the locked lens
     from 0.40 to 1.0 in 0.05 steps, then 0.01 steps around the best,
     scoring two frames per position by luma gradient energy, and locking
     the sharpest (about 4 s, visible in the recording). If every position
     scores within 2% (no detail to judge), it falls back to `autofocus`.
     Android ignores `sweepFocus`.
5. **Segments with no (iOS) or minimal (Android) gaps.** Recording is
   split into files of about `segmentDurationMs`.
   - iOS: video + audio data outputs feeding `AVAssetWriter`, rotating to a
     new writer at a video frame boundary and splitting audio at the same
     timestamp. No dropped frames.
   - Android: `MediaRecorder` only switches files on its **file-size**
     limit (there is no duration-based switch). Segments are cut with
     `setMaxFileSize` (bitrate x duration, capped at 3.8 GB) and
     `setNextOutputFile` on `MEDIA_RECORDER_INFO_MAX_FILESIZE_APPROACHING`.
     Durations are approximate (usually a little over, since encoders run
     under target bitrate) and a few frames can drop at each switch while
     the encoder produces a keyframe. Each segment reports its measured
     duration and start time, so processing places it on the timeline.
     Fully gap-free Android would need a custom MediaCodec + MediaMuxer
     pipeline.
6. **Files.** `<directory>/<filePrefix>_<index padded to 3>.mp4`, e.g.
   `abc_000.mp4`. MP4 container, requested codec and bitrate, constant
   target frame rate.
7. **Audio is required.** AAC, 48 kHz, ~128 kbps. Processing aligns the
   two phones by cross-correlating audio.
8. **`startedAtDeviceMs`** is the wall-clock time of the segment's first
   frame, as precisely as the platform allows (iOS: convert the first
   sample's host-clock timestamp; Android: best estimate). The
   `startRecording` result is the same value for segment 0.
9. **Low storage.** If free space falls below 500 MB while recording, stop,
   finalize, and send a fatal `error` with code `io_error`.
10. **Crash resilience (iOS).** Set `AVAssetWriter.movieFragmentInterval`
    (~10 s) so a crash leaves a playable partial segment.
