// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Plain data types shared by the protocol, the recording store and the
/// manifest builder. All of them round-trip through JSON.
library;

import 'dart:math' as math;

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
    this.darkenScreen = true,
  });

  factory RecordingSettings.fromJson(Map<String, Object?> j) =>
      RecordingSettings(
        resolution: Resolution.values.byName(j['resolution'] as String),
        lockExposure: j['lockExposure'] as bool,
        segmentMinutes: j['segmentMinutes'] as int,
        // Absent in settings saved (or sent over BLE) by older versions.
        darkenScreen: j['darkenScreen'] as bool? ?? true,
      );

  final Resolution resolution;
  final bool lockExposure;
  final int segmentMinutes;

  /// Black out the screen at minimum brightness 15 s into a recording, to
  /// save battery and heat. Tap to wake. Main sends this to Secondary.
  final bool darkenScreen;

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
    bool? darkenScreen,
  }) =>
      RecordingSettings(
        resolution: resolution ?? this.resolution,
        lockExposure: lockExposure ?? this.lockExposure,
        segmentMinutes: segmentMinutes ?? this.segmentMinutes,
        darkenScreen: darkenScreen ?? this.darkenScreen,
      );

  Map<String, Object?> toJson() => {
        'resolution': resolution.name,
        'lockExposure': lockExposure,
        'segmentMinutes': segmentMinutes,
        'darkenScreen': darkenScreen,
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

/// How the phone was held while recording, from gravity. Becomes the
/// manifest device's `orientation`. Mounting the two phones as close
/// together as possible usually puts one of them upside down.
class MountOrientation {
  const MountOrientation({
    required this.uprightRotationDeg,
    required this.rollDeg,
    required this.pitchDeg,
  });

  /// From which way is up in the recorded picture (see [UpVector]).
  factory MountOrientation.fromUp(UpVector up) {
    const toDeg = 180 / math.pi;
    // Where up points, clockwise from the picture's top. The scene is
    // turned clockwise by this much.
    final roll = math.atan2(up.x, up.y) * toDeg;
    final quarters = (roll / 90).round();
    final len = math.sqrt(up.x * up.x + up.y * up.y + up.z * up.z);
    final pitch = len == 0 ? 0.0 : math.asin((-up.z / len).clamp(-1.0, 1.0)) * toDeg;
    double tenth(double v) => (v * 10).round() / 10;
    return MountOrientation(
      uprightRotationDeg: ((-quarters * 90) % 360 + 360) % 360,
      rollDeg: tenth(roll - quarters * 90),
      pitchDeg: tenth(pitch),
    );
  }

  factory MountOrientation.fromJson(Map<String, Object?> j) => MountOrientation(
        uprightRotationDeg: j['uprightRotationDeg'] as int,
        rollDeg: (j['rollDeg'] as num).toDouble(),
        pitchDeg: (j['pitchDeg'] as num).toDouble(),
      );

  /// Clockwise rotation (0, 90, 180 or 270) that makes the video upright:
  /// 180 for a phone mounted upside down.
  final int uprightRotationDeg;

  /// After that rotation, how far the scene is still turned clockwise
  /// (-45..45): positive means the horizon falls to the right.
  final double rollDeg;

  /// The camera's angle above the horizontal: negative when it looks down
  /// at the field.
  final double pitchDeg;

  Map<String, Object?> toJson() => {
        'uprightRotationDeg': uprightRotationDeg,
        'rollDeg': rollDeg,
        'pitchDeg': pitchDeg,
      };
}

/// One time white balance and focus were locked during a recording (see
/// `SettleWatcher`). Becomes an entry of the manifest device's
/// `settingsLocks`, so processing knows from when the picture is steady.
class SettingsLock {
  const SettingsLock({
    required this.atDeviceMs,
    required this.reason,
    required this.whiteBalanceLocked,
    required this.focusLocked,
    required this.exposureLocked,
    this.focus,
    this.orientation,
  });

  factory SettingsLock.fromJson(Map<String, Object?> j) => SettingsLock(
        atDeviceMs: j['atDeviceMs'] as int,
        reason: j['reason'] as String,
        whiteBalanceLocked: j['whiteBalanceLocked'] as bool,
        focusLocked: j['focusLocked'] as bool,
        exposureLocked: j['exposureLocked'] as bool,
        focus: (j['focus'] as Map?)?.cast<String, Object?>(),
        orientation: j['orientation'] == null
            ? null
            : MountOrientation.fromJson((j['orientation'] as Map).cast()),
      );

  /// Device wall clock when the lock took effect.
  final int atDeviceMs;

  /// `settled` or `timeout` (`LockReason`).
  final String reason;
  final bool whiteBalanceLocked;
  final bool focusLocked;
  final bool exposureLocked;

  /// How focus was chosen ([FocusLock], as the manifest has it).
  final Map<String, Object?>? focus;

  /// Which way up the phone was when it locked.
  final MountOrientation? orientation;

  static Map<String, Object?> focusJson(FocusLock f) => {
        'method': f.method,
        if (f.lensPosition != null) 'lensPosition': f.lensPosition,
        if (f.autofocusLensPosition != null) 'autofocusLensPosition': f.autofocusLensPosition,
        if (f.sweep.isNotEmpty)
          'sweep': [
            for (final s in f.sweep) {'lensPosition': s.lensPosition, 'sharpness': s.sharpness},
          ],
      };

  Map<String, Object?> toJson() => {
        'atDeviceMs': atDeviceMs,
        'reason': reason,
        'whiteBalanceLocked': whiteBalanceLocked,
        'focusLocked': focusLocked,
        'exposureLocked': exposureLocked,
        if (focus != null) 'focus': focus,
        if (orientation != null) 'orientation': orientation!.toJson(),
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

/// Main's permission for this phone to upload its own part of one game
/// into Main's account (docs/API.md, "Recording grants"). Main gets it from
/// the server and sends it over Bluetooth; the upload queue uses [token]
/// instead of this phone's own device token for that game.
class RecordingGrant {
  const RecordingGrant({
    required this.apiUrl,
    required this.token,
    required this.accountId,
    required this.gameId,
    required this.expiresAt,
    this.rejected = false,
    this.unredeemed = false,
  });

  factory RecordingGrant.fromJson(Map<String, Object?> j) => RecordingGrant(
        apiUrl: j['apiUrl'] as String,
        token: j['token'] as String,
        accountId: j['accountId'] as String,
        gameId: j['gameId'] as String,
        expiresAt: DateTime.parse(j['expiresAt'] as String),
        rejected: j['rejected'] as bool? ?? false,
        unredeemed: j['unredeemed'] as bool? ?? false,
      );

  final String apiUrl;
  final String token;

  /// Main's account, where the footage goes.
  final String accountId;
  final String gameId;
  final DateTime expiresAt;

  /// The server answered 401 (expired or replaced).
  final bool rejected;

  /// A grant ticket Main handed over without signal (docs/API.md,
  /// `POST /grant-tickets`): it must be bound to this game and phone
  /// (`POST /grants/redeem`) before it can upload. [expiresAt] is only an
  /// estimate until then.
  final bool unredeemed;

  bool usableAt(DateTime now) => !rejected && now.isBefore(expiresAt);

  RecordingGrant asRejected() => RecordingGrant(
      apiUrl: apiUrl,
      token: token,
      accountId: accountId,
      gameId: gameId,
      expiresAt: expiresAt,
      rejected: true,
      unredeemed: unredeemed);

  /// After `POST /grants/redeem`: an ordinary grant until [expiresAt].
  RecordingGrant redeemed(DateTime expiresAt) =>
      RecordingGrant(apiUrl: apiUrl, token: token, accountId: accountId, gameId: gameId, expiresAt: expiresAt);

  Map<String, Object?> toJson() => {
        'apiUrl': apiUrl,
        'token': token,
        'accountId': accountId,
        'gameId': gameId,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        if (rejected) 'rejected': true,
        if (unredeemed) 'unredeemed': true,
      };
}
