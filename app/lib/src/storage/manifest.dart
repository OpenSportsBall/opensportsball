// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/// Builds the upload manifest defined in
/// `shared/schemas/manifest.schema.json`. The schema's `sessionId` is one
/// start-to-stop recording, which the app calls a recording.
library;

import '../model.dart';
import 'store.dart';

/// S3 key each segment uploads to.
String objectKey(String gameId, String recordingId, String deviceId, String fileName) =>
    'games/$gameId/recordings/$recordingId/$deviceId/$fileName';

/// Returns null until Main has everything: its own stopped recording and
/// all of Secondary's segments.
Map<String, Object?>? buildManifest(LocalRecording main, {DateTime? now}) {
  final peer = main.peer;
  final mainVideo = main.video;
  if (!main.stopped || mainVideo == null || main.segments.isEmpty) return null;
  if (peer == null || !peer.complete || peer.video == null || peer.clock == null) {
    return null;
  }

  Map<String, Object?> device(
    DeviceIdentity id,
    String role,
    VideoInfo video,
    Iterable<SegmentRecord> segments,
  ) =>
      {
        'deviceId': id.deviceId,
        'role': role,
        'position': 'unknown',
        'platform': id.platform,
        'model': id.model,
        'appVersion': id.appVersion,
        'video': {
          'width': video.width,
          'height': video.height,
          'nominalFps': video.nominalFps,
          'codec': video.codec,
          'bitrateBps': video.bitrateBps,
          'lens': video.lens,
          'stabilization': false,
          if (video.horizontalFovDeg != null) 'horizontalFovDeg': video.horizontalFovDeg,
        },
        'segments': [
          for (final s in segments)
            {
              'index': s.index,
              'objectKey': objectKey(main.gameId, main.recordingId, id.deviceId, s.fileName),
              'bytes': s.bytes,
              'sha256': s.sha256,
              'startedAtDeviceMs': s.startedAtDeviceMs,
              'durationMs': s.durationMs,
            },
        ],
      };

  final peerSegments = [for (final i in peer.segments.keys.toList()..sort()) peer.segments[i]!];
  final clock = peer.clock!;
  return {
    'schemaVersion': 1,
    'gameId': main.gameId,
    'sessionId': main.recordingId,
    'createdAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'devices': [
      device(main.device, 'main', mainVideo, main.segments),
      device(peer.device, 'secondary', peer.video!, peerSegments),
    ],
    'clockSync': {
      'secondaryOffsetMs': clock.secondaryOffsetMs,
      'medianRttMs': clock.medianRttMs,
      'samples': clock.samples,
    },
  };
}
