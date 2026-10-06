// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/// Plain data types shared by the protocol, the recording store and the
/// manifest builder. All of them round-trip through JSON.
library;

import 'package:dual_camera/dual_camera.dart';

const kAppVersion = '0.1.0';

/// Who this phone is. `deviceId` is generated once and persisted.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.platform,
    required this.model,
    this.appVersion = kAppVersion,
  });

  factory DeviceIdentity.fromJson(Map<String, Object?> j) => DeviceIdentity(
        deviceId: j['deviceId'] as String,
        platform: j['platform'] as String,
        model: j['model'] as String,
        appVersion: j['appVersion'] as String? ?? kAppVersion,
      );

  final String deviceId;

  /// `ios` or `android`, matching the manifest schema.
  final String platform;
  final String model;
  final String appVersion;

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'platform': platform,
        'model': model,
        'appVersion': appVersion,
      };
}

/// User-facing recording settings. Main sends these to Secondary so both
/// phones record the same way.
class RecordingSettings {
  const RecordingSettings({
    this.resolution = Resolution.uhd4k,
    this.lockExposure = false,
    this.segmentMinutes = 5,
  });

  factory RecordingSettings.fromJson(Map<String, Object?> j) =>
      RecordingSettings(
        resolution: Resolution.values.byName(j['resolution'] as String),
        lockExposure: j['lockExposure'] as bool,
        segmentMinutes: j['segmentMinutes'] as int,
      );

  final Resolution resolution;
  final bool lockExposure;
  final int segmentMinutes;

  CaptureConfig toCaptureConfig() => CaptureConfig(
        width: resolution.width,
        height: resolution.height,
        fps: 30,
        codec: VideoCodec.hevc,
        bitrateBps: resolution.bitrateBps,
        lens: Lens.ultrawide,
        segmentDuration: Duration(minutes: segmentMinutes),
        lockExposure: lockExposure,
      );

  RecordingSettings copyWith({
    Resolution? resolution,
    bool? lockExposure,
    int? segmentMinutes,
  }) =>
      RecordingSettings(
        resolution: resolution ?? this.resolution,
        lockExposure: lockExposure ?? this.lockExposure,
        segmentMinutes: segmentMinutes ?? this.segmentMinutes,
      );

  Map<String, Object?> toJson() => {
        'resolution': resolution.name,
        'lockExposure': lockExposure,
        'segmentMinutes': segmentMinutes,
      };
}

/// This phone's upload preferences. Not sent over BLE.
class UploadSettings {
  const UploadSettings({this.wifiOnly = true, this.lastApiUrl});

  factory UploadSettings.fromJson(Map<String, Object?> j) => UploadSettings(
        wifiOnly: j['wifiOnly'] as bool? ?? true,
        lastApiUrl: j['lastApiUrl'] as String?,
      );

  /// Upload only on Wi-Fi (or Ethernet), never on mobile data.
  final bool wifiOnly;

  /// API of the most recent link, kept after unlinking so a code can be
  /// typed instead of scanned next time.
  final String? lastApiUrl;

  UploadSettings copyWith({bool? wifiOnly, String? lastApiUrl}) => UploadSettings(
        wifiOnly: wifiOnly ?? this.wifiOnly,
        lastApiUrl: lastApiUrl ?? this.lastApiUrl,
      );

  Map<String, Object?> toJson() => {
        'wifiOnly': wifiOnly,
        if (lastApiUrl != null) 'lastApiUrl': lastApiUrl,
      };
}

enum Resolution {
  uhd4k('4K', 3840, 2160, 35000000),
  hd1080('1080p', 1920, 1080, 16000000);

  const Resolution(this.label, this.width, this.height, this.bitrateBps);

  final String label;
  final int width;
  final int height;
  final int bitrateBps;
}

/// How a phone actually recorded, after camera fallbacks. Becomes the
/// manifest's `video` object.
class VideoInfo {
  const VideoInfo({
    required this.width,
    required this.height,
    required this.nominalFps,
    required this.codec,
    required this.lens,
    required this.bitrateBps,
    this.horizontalFovDeg,
  });

  factory VideoInfo.fromOpen(OpenResult o, CaptureConfig c) => VideoInfo(
        width: o.width,
        height: o.height,
        nominalFps: o.fps,
        codec: o.codec.name,
        lens: o.lens.name,
        bitrateBps: c.bitrateBps,
        horizontalFovDeg: o.horizontalFovDeg,
      );

  factory VideoInfo.fromJson(Map<String, Object?> j) => VideoInfo(
        width: j['width'] as int,
        height: j['height'] as int,
        nominalFps: j['nominalFps'] as int,
        codec: j['codec'] as String,
        lens: j['lens'] as String,
        bitrateBps: j['bitrateBps'] as int,
        horizontalFovDeg: (j['horizontalFovDeg'] as num?)?.toDouble(),
      );

  final int width;
  final int height;
  final int nominalFps;
  final String codec;
  final String lens;
  final int bitrateBps;
  final double? horizontalFovDeg;

  Map<String, Object?> toJson() => {
        'width': width,
        'height': height,
        'nominalFps': nominalFps,
        'codec': codec,
        'lens': lens,
        'bitrateBps': bitrateBps,
        if (horizontalFovDeg != null) 'horizontalFovDeg': horizontalFovDeg,
      };
}

/// One finished, hashed segment file.
class SegmentRecord {
  const SegmentRecord({
    required this.index,
    required this.fileName,
    required this.bytes,
    required this.sha256,
    required this.startedAtDeviceMs,
    required this.durationMs,
  });

  factory SegmentRecord.fromJson(Map<String, Object?> j) => SegmentRecord(
        index: j['index'] as int,
        fileName: j['fileName'] as String,
        bytes: j['bytes'] as int,
        sha256: j['sha256'] as String,
        startedAtDeviceMs: j['startedAtDeviceMs'] as int,
        durationMs: j['durationMs'] as int,
      );

  final int index;
  final String fileName;
  final int bytes;
  final String sha256;
  final int startedAtDeviceMs;
  final int durationMs;

  Map<String, Object?> toJson() => {
        'index': index,
        'fileName': fileName,
        'bytes': bytes,
        'sha256': sha256,
        'startedAtDeviceMs': startedAtDeviceMs,
        'durationMs': durationMs,
      };
}

/// Result of BLE clock sync: `secondary clock - main clock`.
class ClockEstimate {
  const ClockEstimate({
    required this.secondaryOffsetMs,
    required this.medianRttMs,
    required this.samples,
  });

  factory ClockEstimate.fromJson(Map<String, Object?> j) => ClockEstimate(
        secondaryOffsetMs: (j['secondaryOffsetMs'] as num).toDouble(),
        medianRttMs: (j['medianRttMs'] as num).toDouble(),
        samples: j['samples'] as int,
      );

  final double secondaryOffsetMs;
  final double medianRttMs;
  final int samples;

  Map<String, Object?> toJson() => {
        'secondaryOffsetMs': secondaryOffsetMs,
        'medianRttMs': medianRttMs,
        'samples': samples,
      };
}
