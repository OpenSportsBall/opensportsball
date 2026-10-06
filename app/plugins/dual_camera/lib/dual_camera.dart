// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/// Dart-side contract for the native camera plugin. The Android side is
/// built on CameraX / Camera2 and the iOS side on AVFoundation; neither is
/// written yet.
library;

enum Lens { ultrawide, wide }

enum VideoCodec { hevc, h264 }

class CaptureConfig {
  const CaptureConfig({
    this.width = 3840,
    this.height = 2160,
    this.fps = 30,
    this.codec = VideoCodec.hevc,
    this.bitrateBps = 35000000,
    this.lens = Lens.ultrawide,
    this.segmentDuration = const Duration(minutes: 5),
  });

  final int width;
  final int height;
  final int fps;
  final VideoCodec codec;
  final int bitrateBps;
  final Lens lens;

  /// Recording is split into files of this length so a crash loses at most
  /// one segment and uploads can resume per segment.
  final Duration segmentDuration;
}

/// One finished segment file, reported as soon as the native side closes it.
class SegmentInfo {
  const SegmentInfo({
    required this.index,
    required this.path,
    required this.bytes,
    required this.startedAtDeviceMs,
    required this.duration,
  });

  final int index;
  final String path;
  final int bytes;

  /// Device clock (ms since epoch) when the segment's first frame was
  /// captured.
  final int startedAtDeviceMs;
  final Duration duration;
}

class DeviceStatus {
  const DeviceStatus({
    required this.batteryPercent,
    required this.freeStorageBytes,
    required this.thermalState,
  });

  final int batteryPercent;
  final int freeStorageBytes;

  /// Platform thermal state normalized to nominal / fair / serious /
  /// critical.
  final String thermalState;
}

abstract class DualCamera {
  /// Opens the camera with [config]. Stabilization is always off: it moves
  /// the image frame to frame and breaks the fixed stitch.
  Future<void> open(CaptureConfig config);

  /// Meters the scene once, then locks exposure, focus (at infinity) and
  /// white balance for the rest of the session so both phones match.
  Future<void> lockSettings();

  Future<void> startRecording();
  Future<void> stopRecording();

  /// Emits each segment as it is finalized.
  Stream<SegmentInfo> get segments;

  Future<DeviceStatus> status();

  Future<void> close();
}
