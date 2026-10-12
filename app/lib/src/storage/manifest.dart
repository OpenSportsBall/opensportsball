// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Builds what each phone uploads about a recording, using
/// `shared/schemas/manifest.schema.json`. The schema's `sessionId` is one
/// start-to-stop recording, which the app calls a recording.
///
/// Main uploads the manifest: both phones, but only Main's own segments.
/// Every other phone uploads a report of its own segments (the schema's
/// device entry) whenever it reaches Wi-Fi. The phones never need to be
/// near each other after recording; the server merges the two.
library;

import '../model.dart';
import 'store.dart';

/// Segment path relative to the recording. The server decides the full
/// bucket key (it adds the account, game and recording).
String objectKey(String deviceId, String fileName) => '$deviceId/$fileName';

Map<String, Object?> _device(
  DeviceIdentity id,
  String role,
  VideoInfo video, [
  Iterable<SegmentRecord>? segments,
]) =>
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
      if (segments != null)
        'segments': [
          for (final s in segments)
            {
              'index': s.index,
              'objectKey': objectKey(id.deviceId, s.fileName),
              'bytes': s.bytes,
              'sha256': s.sha256,
              'startedAtDeviceMs': s.startedAtDeviceMs,
              'durationMs': s.durationMs,
            },
        ],
    };

/// Main's manifest, once Main has stopped. It names the Secondary (known
/// from pairing) without its segments: the Secondary reports those itself.
/// A recording made on Main alone gets a one-device manifest.
Map<String, Object?>? buildManifest(LocalRecording main, {DateTime? now}) {
  final peer = main.peer;
  final mainVideo = main.video;
  if (!main.stopped || mainVideo == null || main.segments.isEmpty) return null;

  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'gameId': main.gameId,
    'sessionId': main.recordingId,
    'createdAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'devices': [_device(main.device, 'main', mainVideo, main.segments)],
  };
  // Secondary said how it records when it got ready (Prepared). Left out if
  // it is known to have recorded nothing.
  if (peer != null && peer.video != null && peer.expectedSegments != 0) {
    (manifest['devices']! as List).add(_device(peer.device, 'secondary', peer.video!));
    final clock = peer.clock;
    if (clock != null) {
      manifest['clockSync'] = {
        'secondaryOffsetMs': clock.secondaryOffsetMs,
        'medianRttMs': clock.medianRttMs,
        'samples': clock.samples,
      };
    }
  }
  return manifest;
}

/// A non-Main phone's report of its own part of [rec], once it has stopped.
Map<String, Object?>? buildReport(LocalRecording rec) {
  final video = rec.video;
  if (!rec.stopped || video == null || rec.segments.isEmpty) return null;
  return _device(rec.device, rec.role.name, video, rec.segments);
}
