# dual_camera

Native camera control for stitchable two-phone recording. License:
Apache-2.0.

The Dart contract is in `lib/dual_camera.dart`. The native sides are
template stubs for now:

- Android: `android/src/main/kotlin/.../DualCameraPlugin.kt`, to be built on
  CameraX / Camera2.
- iOS: `ios/dual_camera/Sources/dual_camera/DualCameraPlugin.swift`, to be
  built on AVFoundation.

Requirements both sides must meet: exposure, focus (at infinity) and white
balance locked after one metering pass; stabilization off; ultra-wide lens;
configurable codec and bitrate; output split into segments with the
device-clock start time of each segment's first frame.
