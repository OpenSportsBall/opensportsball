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
    this.focus,
  });

  factory LockResult.fromMap(Map<Object?, Object?> m) => LockResult(
        exposureLocked: m['exposureLocked'] as bool,
        whiteBalanceLocked: m['whiteBalanceLocked'] as bool,
        focusLocked: m['focusLocked'] as bool,
        focus: m['focus'] == null ? null : FocusLock.fromMap(m['focus'] as Map<Object?, Object?>),
      );

  final bool exposureLocked;
  final bool whiteBalanceLocked;
  final bool focusLocked;

  /// How focus was chosen, if the platform says.
  final FocusLock? focus;
}

/// How [DualCamera.lockSettings] chose the focus it locked.
class FocusLock {
  const FocusLock({
    required this.method,
    this.lensPosition,
    this.autofocusLensPosition,
    this.sweep = const [],
  });

  factory FocusLock.fromMap(Map<Object?, Object?> m) => FocusLock(
        method: m['method'] as String,
        lensPosition: (m['lensPosition'] as num?)?.toDouble(),
        autofocusLensPosition: (m['autofocusLensPosition'] as num?)?.toDouble(),
        sweep: [
          for (final s in (m['sweep'] as List?) ?? const [])
            FocusSample(
              ((s as Map)['lensPosition'] as num).toDouble(),
              (s['sharpness'] as num).toDouble(),
            ),
        ],
      );

  /// `sweep` (the sharpest lens position of a sweep, iOS), `autofocus`
  /// (where autofocus settled), `infinity` (Android's calibrated infinity),
  /// `fixed` (the lens can't focus) or `none` (focus could not be locked).
  final String method;

  /// The locked lens position (iOS, 0 near .. 1 far; not a distance).
  final double? lensPosition;

  /// Where continuous autofocus had settled before locking (iOS).
  final double? autofocusLensPosition;

  /// The sweep's measurements, in the order taken.
  final List<FocusSample> sweep;
}

class FocusSample {
  const FocusSample(this.lensPosition, this.sharpness);

  final double lensPosition;

  /// Mean gradient strength of the picture; only comparable within one
  /// sweep.
  final double sharpness;
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

/// Which way is up, as a unit vector in the recorded picture's axes: x to
/// its right, y to its top, z out of the screen (the back camera looks
/// along -z).
class UpVector {
  const UpVector(this.x, this.y, this.z);

  factory UpVector.fromMap(Map<Object?, Object?> m) =>
      UpVector((m['x'] as num).toDouble(), (m['y'] as num).toDouble(), (m['z'] as num).toDouble());

  final double x;
  final double y;
  final double z;
}

/// How the phone moved since the previous [DualCamera.motion] call.
class MotionWindow {
  const MotionWindow({
    required this.samples,
    this.up,
    this.maxRotationDegPerS,
    this.maxAccelerationG,
  });

  factory MotionWindow.fromMap(Map<Object?, Object?> m) => MotionWindow(
        samples: m['samples'] as int,
        up: m['up'] == null ? null : UpVector.fromMap(m['up'] as Map<Object?, Object?>),
        maxRotationDegPerS: (m['maxRotationDegPerS'] as num?)?.toDouble(),
        maxAccelerationG: (m['maxAccelerationG'] as num?)?.toDouble(),
      );

  /// Sensor readings in the window; 0 on the first call or without sensors.
  final int samples;

  /// Which way is up, averaged over the window.
  final UpVector? up;

  /// Fastest turn (gyroscope), or null without one.
  final double? maxRotationDegPerS;

  /// Largest acceleration apart from gravity, in g, or null without a
  /// sensor for it.
  final double? maxAccelerationG;
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
  /// exposure, if the config asked for it) until the next call. Works while
  /// recording. With [sweepFocus], an iOS phone steps the lens through its
  /// range and locks the sharpest position (a few seconds of visible
  /// refocusing) instead of trusting autofocus; Android locks its
  /// calibrated infinity either way.
  Future<LockResult> lockSettings({bool sweepFocus = false}) async => LockResult.fromMap(
      (await _methods.invokeMapMethod('lockSettings', {'sweepFocus': sweepFocus}))!);

  /// Starts recording segments named `<filePrefix>_000.mp4`, ... into
  /// [directory]. Returns the device time of the first frame.
  ///
  /// [uprightRotationDeg] (0, 90, 180 or 270, clockwise) is written into
  /// the files as display rotation, so players show a phone mounted upside
  /// down the right way up. The pixels are not rotated.
  Future<int> startRecording({
    required String directory,
    required String filePrefix,
    int uprightRotationDeg = 0,
  }) async {
    final r = await _methods.invokeMapMethod('startRecording', {
      'directory': directory,
      'filePrefix': filePrefix,
      'uprightRotationDeg': uprightRotationDeg,
    });
    return r!['startedAtDeviceMs'] as int;
  }

  /// Returns after the last segment is finalized and reported.
  Future<void> stopRecording() => _methods.invokeMethod('stopRecording');

  Future<DeviceStatus> status() async =>
      DeviceStatus.fromMap((await _methods.invokeMapMethod('status'))!);

  /// Which way is up for the camera right now (gravity, averaged over a
  /// moment), or null if the phone can't tell.
  Future<UpVector?> orientation() async {
    final m = await _methods.invokeMapMethod<Object?, Object?>('orientation');
    return m == null ? null : UpVector.fromMap(m);
  }

  /// How the phone moved since the previous call. The first call starts
  /// the motion sensors (and returns an empty window); [stopMotion] stops
  /// them.
  Future<MotionWindow> motion() async =>
      MotionWindow.fromMap((await _methods.invokeMapMethod('motion'))!);

  Future<void> stopMotion() => _methods.invokeMethod('stopMotion');

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
