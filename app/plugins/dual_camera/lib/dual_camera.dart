// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Camera control for stitchable two-phone recording. The platform channel
/// contract is documented in CHANNEL.md; the Android side is built on
/// Camera2 + MediaRecorder and the iOS side on AVFoundation + AVAssetWriter.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum Lens { ultrawide, wide }

enum VideoCodec { hevc, h264 }

enum ThermalState { nominal, fair, serious, critical }

class CaptureConfig {
  const CaptureConfig({
    this.width = 3840,
    this.height = 2160,
    this.fps = 30,
    this.codec = VideoCodec.hevc,
    this.bitrateBps = 35000000,
    this.lens = Lens.ultrawide,
    this.segmentDuration = const Duration(minutes: 5),
    this.lockExposure = false,
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

  /// Lock exposure as well as white balance and focus. Off by default:
  /// light changes over a game, and processing matches brightness between
  /// the two phones frame by frame.
  final bool lockExposure;

  Map<String, Object> toMap() => {
        'width': width,
        'height': height,
        'fps': fps,
        'codec': codec.name,
        'bitrateBps': bitrateBps,
        'lens': lens.name,
        'segmentDurationMs': segmentDuration.inMilliseconds,
        'lockExposure': lockExposure,
      };
}

/// What the camera actually opened with, after any fallbacks.
class OpenResult {
  const OpenResult({
    required this.textureId,
    required this.previewWidth,
    required this.previewHeight,
    required this.width,
    required this.height,
    required this.fps,
    required this.codec,
    required this.lens,
    this.horizontalFovDeg,
  });

  factory OpenResult.fromMap(Map<Object?, Object?> m) => OpenResult(
        textureId: m['textureId'] as int,
        previewWidth: m['previewWidth'] as int,
        previewHeight: m['previewHeight'] as int,
        width: m['width'] as int,
        height: m['height'] as int,
        fps: m['fps'] as int,
        codec: VideoCodec.values.byName(m['codec'] as String),
        lens: Lens.values.byName(m['lens'] as String),
        horizontalFovDeg: (m['horizontalFovDeg'] as num?)?.toDouble(),
      );

  final int textureId;
  final int previewWidth;
  final int previewHeight;
  final int width;
  final int height;
  final int fps;
  final VideoCodec codec;
  final Lens lens;
  final double? horizontalFovDeg;
}

class LockResult {
  const LockResult({
    required this.exposureLocked,
    required this.whiteBalanceLocked,
    required this.focusLocked,
  });

  factory LockResult.fromMap(Map<Object?, Object?> m) => LockResult(
        exposureLocked: m['exposureLocked'] as bool,
        whiteBalanceLocked: m['whiteBalanceLocked'] as bool,
        focusLocked: m['focusLocked'] as bool,
      );

  final bool exposureLocked;
  final bool whiteBalanceLocked;
  final bool focusLocked;
}

class Permissions {
  const Permissions({required this.camera, required this.microphone});

  factory Permissions.fromMap(Map<Object?, Object?> m) => Permissions(
        camera: m['camera'] as bool,
        microphone: m['microphone'] as bool,
      );

  final bool camera;
  final bool microphone;

  bool get all => camera && microphone;
}

class DeviceStatus {
  const DeviceStatus({
    required this.batteryPercent,
    required this.charging,
    required this.freeStorageBytes,
    required this.thermalState,
    required this.recording,
  });

  factory DeviceStatus.fromMap(Map<Object?, Object?> m) => DeviceStatus(
        batteryPercent: m['batteryPercent'] as int,
        charging: m['charging'] as bool,
        freeStorageBytes: m['freeStorageBytes'] as int,
        thermalState: ThermalState.values.byName(m['thermalState'] as String),
        recording: m['recording'] as bool,
      );

  final int batteryPercent;
  final bool charging;
  final int freeStorageBytes;
  final ThermalState thermalState;
  final bool recording;
}

sealed class CameraEvent {
  const CameraEvent();

  static CameraEvent fromMap(Map<Object?, Object?> m) {
    switch (m['type']) {
      case 'segment':
        return SegmentEvent(
          index: m['index'] as int,
          path: m['path'] as String,
          bytes: m['bytes'] as int,
          startedAtDeviceMs: m['startedAtDeviceMs'] as int,
          duration: Duration(milliseconds: m['durationMs'] as int),
        );
      case 'error':
        return CameraErrorEvent(
          code: m['code'] as String,
          message: m['message'] as String,
          fatal: m['fatal'] as bool,
        );
      case 'interrupted':
        return InterruptedEvent(m['reason'] as String);
      default:
        return CameraErrorEvent(
          code: 'internal',
          message: 'unknown camera event: ${m['type']}',
          fatal: false,
        );
    }
  }
}

/// One finished segment file, sent once the native side has closed it.
class SegmentEvent extends CameraEvent {
  const SegmentEvent({
    required this.index,
    required this.path,
    required this.bytes,
    required this.startedAtDeviceMs,
    required this.duration,
  });

  final int index;
  final String path;
  final int bytes;

  /// Device wall clock (ms since epoch) when the first frame was captured.
  final int startedAtDeviceMs;
  final Duration duration;
}

class CameraErrorEvent extends CameraEvent {
  const CameraErrorEvent({
    required this.code,
    required this.message,
    required this.fatal,
  });

  final String code;
  final String message;

  /// Recording has stopped; finished segments were already reported.
  final bool fatal;
}

/// The OS took the camera away (call, backgrounding, thermal shutdown).
/// Recording has stopped.
class InterruptedEvent extends CameraEvent {
  const InterruptedEvent(this.reason);

  final String reason;
}

class DualCamera {
  DualCamera({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methods =
            methodChannel ?? const MethodChannel('dev.opensportsball/dual_camera'),
        _events = eventChannel ??
            const EventChannel('dev.opensportsball/dual_camera/events');

  final MethodChannel _methods;
  final EventChannel _events;

  Stream<CameraEvent>? _eventStream;

  /// Segment, error and interruption events. Broadcast; listen before
  /// [startRecording].
  Stream<CameraEvent> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .map((e) => CameraEvent.fromMap(e as Map<Object?, Object?>))
      .asBroadcastStream();

  Future<Permissions> checkPermissions() async =>
      Permissions.fromMap((await _methods.invokeMapMethod('checkPermissions'))!);

  Future<Permissions> requestPermissions() async => Permissions.fromMap(
      (await _methods.invokeMapMethod('requestPermissions'))!);

  /// Asks for the Bluetooth permission ("Nearby devices" on Android 12+)
  /// if needed, and returns whether it is granted. On iOS the system asks on
  /// first use, so this returns true.
  Future<bool> requestBluetoothPermission() async =>
      await _methods.invokeMethod<bool>('requestBluetoothPermission') ?? false;

  Future<List<Lens>> availableLenses() async {
    final names = await _methods.invokeListMethod<String>('availableLenses');
    return [for (final n in names ?? const <String>[]) Lens.values.byName(n)];
  }

  /// Opens the camera with [config] and starts the preview. Stabilization
  /// is always off: it moves the image frame to frame and breaks the fixed
  /// stitch.
  Future<OpenResult> open(CaptureConfig config) async => OpenResult.fromMap(
      (await _methods.invokeMapMethod('open', config.toMap()))!);

  /// Meters the scene once, then locks white balance and focus (and
  /// exposure, if the config asked for it) for the rest of the session.
  Future<LockResult> lockSettings() async =>
      LockResult.fromMap((await _methods.invokeMapMethod('lockSettings'))!);

  /// Starts recording segments named `<filePrefix>_000.mp4`, ... into
  /// [directory]. Returns the device time of the first frame.
  Future<int> startRecording({
    required String directory,
    required String filePrefix,
  }) async {
    final r = await _methods.invokeMapMethod('startRecording', {
      'directory': directory,
      'filePrefix': filePrefix,
    });
    return r!['startedAtDeviceMs'] as int;
  }

  /// Returns after the last segment is finalized and reported.
  Future<void> stopRecording() => _methods.invokeMethod('stopRecording');

  Future<DeviceStatus> status() async =>
      DeviceStatus.fromMap((await _methods.invokeMapMethod('status'))!);

  Future<void> setKeepScreenOn(bool on) =>
      _methods.invokeMethod('setKeepScreenOn', {'on': on});

  /// Overrides screen brightness (0..1) while the app is in front; null
  /// hands it back to the system.
  Future<void> setScreenBrightness(double? level) =>
      _methods.invokeMethod('setScreenBrightness', {'level': level});

  /// Stops drawing preview frames; the camera and recording keep running.
  Future<void> setPreviewPaused(bool paused) =>
      _methods.invokeMethod('setPreviewPaused', {'paused': paused});

  Future<void> close() => _methods.invokeMethod('close');
}

/// Shows the camera preview for an opened camera.
class DualCameraPreview extends StatelessWidget {
  const DualCameraPreview({super.key, required this.opened});

  final OpenResult opened;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: opened.previewWidth / opened.previewHeight,
      child: Texture(textureId: opened.textureId),
    );
  }
}
