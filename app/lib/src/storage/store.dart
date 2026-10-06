// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/// Local persistence: device identity, settings, and recordings on disk.
///
/// Layout under [AppStore.recordingsRoot]:
///
/// ```
/// <gameId>/<recordingId>/
///   <deviceId>_000.mp4, <deviceId>_001.mp4, ...
///   recording.json     this phone's record (LocalRecording)
///   manifest.json      Main only, once both phones' segments are known
/// ```
///
/// Recordings live where the user can copy them off during testing: the
/// app's Documents folder on iOS (visible in Finder / Files) and the app's
/// external files folder on Android (visible over USB).
library;

import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../model.dart';
import '../role.dart';

class AppStore {
  AppStore._(this._supportDir, this.recordingsRoot, this.identity, this._settings);

  @visibleForTesting
  AppStore.forTest({
    required Directory supportDir,
    required this.recordingsRoot,
    required this.identity,
    RecordingSettings settings = const RecordingSettings(),
  })  : _supportDir = supportDir,
        _settings = settings;

  static Future<AppStore> open() async {
    final support = await getApplicationSupportDirectory();
    final Directory root;
    if (Platform.isAndroid) {
      root = Directory('${(await getExternalStorageDirectory() ?? support).path}/recordings');
    } else {
      root = Directory('${(await getApplicationDocumentsDirectory()).path}/recordings');
    }
    await root.create(recursive: true);
    final identity = await _loadIdentity(support);
    final settings = await _readJson(File('${support.path}/settings.json'));
    return AppStore._(
      support,
      root,
      identity,
      settings == null ? const RecordingSettings() : RecordingSettings.fromJson(settings),
    );
  }

  final Directory _supportDir;
  final Directory recordingsRoot;
  final DeviceIdentity identity;
  RecordingSettings _settings;

  RecordingSettings get settings => _settings;

  Future<void> saveSettings(RecordingSettings s) async {
    _settings = s;
    await _writeJson(File('${_supportDir.path}/settings.json'), s.toJson());
  }

  Directory recordingDir(String gameId, String recordingId) =>
      Directory('${recordingsRoot.path}/$gameId/$recordingId');

  Future<void> saveRecording(LocalRecording r) async {
    final dir = recordingDir(r.gameId, r.recordingId);
    await dir.create(recursive: true);
    await _writeJson(File('${dir.path}/recording.json'), r.toJson());
  }

  Future<void> saveManifest(LocalRecording r, Map<String, Object?> manifest) async {
    final dir = recordingDir(r.gameId, r.recordingId);
    await _writeJson(File('${dir.path}/manifest.json'), manifest);
  }

  /// All recordings on this phone, newest first.
  Future<List<StoredRecording>> listRecordings() async {
    final out = <StoredRecording>[];
    if (!await recordingsRoot.exists()) return out;
    await for (final game in recordingsRoot.list()) {
      if (game is! Directory) continue;
      await for (final rec in game.list()) {
        if (rec is! Directory) continue;
        final json = await _readJson(File('${rec.path}/recording.json'));
        if (json == null) continue;
        out.add(StoredRecording(
          dir: rec,
          recording: LocalRecording.fromJson(json),
          hasManifest: await File('${rec.path}/manifest.json').exists(),
        ));
      }
    }
    out.sort((a, b) => b.recording.createdAtMs.compareTo(a.recording.createdAtMs));
    return out;
  }

  Future<void> deleteRecording(StoredRecording r) async {
    await r.dir.delete(recursive: true);
    final game = r.dir.parent;
    if (await game.list().isEmpty) await game.delete();
  }

  static Future<DeviceIdentity> _loadIdentity(Directory support) async {
    final file = File('${support.path}/device.json');
    final existing = await _readJson(file);
    if (existing != null) return DeviceIdentity.fromJson(existing);

    final info = DeviceInfoPlugin();
    final String model;
    if (Platform.isIOS) {
      model = (await info.iosInfo).utsname.machine; // e.g. "iPhone16,1"
    } else if (Platform.isAndroid) {
      final a = await info.androidInfo;
      model = '${a.manufacturer} ${a.model}';
    } else {
      model = Platform.operatingSystem;
    }
    final identity = DeviceIdentity(
      deviceId: const Uuid().v4(),
      platform: Platform.isIOS ? 'ios' : 'android',
      model: model,
    );
    await _writeJson(file, identity.toJson());
    return identity;
  }
}

Future<Map<String, Object?>?> _readJson(File f) async {
  if (!await f.exists()) return null;
  try {
    return (jsonDecode(await f.readAsString()) as Map).cast();
  } on FormatException {
    return null;
  }
}

final _writesInFlight = <String, Future<void>>{};

/// Write-then-rename so a crash never leaves a half-written file. Writes to
/// the same file are serialized (segments finishing and a stop can save the
/// same recording at once); the last call's content wins.
Future<void> _writeJson(File f, Map<String, Object?> json) {
  final text = const JsonEncoder.withIndent('  ').convert(json);
  final previous = _writesInFlight[f.path] ?? Future.value();
  final next = previous.catchError((_) {}).then((_) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  });
  _writesInFlight[f.path] = next;
  return next.whenComplete(() {
    if (identical(_writesInFlight[f.path], next)) _writesInFlight.remove(f.path);
  });
}

class StoredRecording {
  const StoredRecording({
    required this.dir,
    required this.recording,
    required this.hasManifest,
  });

  final Directory dir;
  final LocalRecording recording;
  final bool hasManifest;

  List<File> get segmentFiles => [
        for (final s in recording.segments) File('${dir.path}/${s.fileName}'),
      ];

  int get totalBytes => recording.segments.fold(0, (sum, s) => sum + s.bytes);
}

/// What one phone knows about one start-to-stop recording. Main also keeps
/// what it has heard from Secondary in [peer].
class LocalRecording {
  LocalRecording({
    required this.recordingId,
    required this.gameId,
    required this.role,
    required this.device,
    required this.createdAtMs,
    this.video,
    this.startedAtDeviceMs,
    this.stoppedAtMs,
    this.endReason,
    List<SegmentRecord>? segments,
    this.peer,
  }) : segments = segments ?? [];

  factory LocalRecording.fromJson(Map<String, Object?> j) => LocalRecording(
        recordingId: j['recordingId'] as String,
        gameId: j['gameId'] as String,
        role: DeviceRole.values.byName(j['role'] as String),
        device: DeviceIdentity.fromJson((j['device'] as Map).cast()),
        createdAtMs: j['createdAtMs'] as int,
        video: j['video'] == null ? null : VideoInfo.fromJson((j['video'] as Map).cast()),
        startedAtDeviceMs: j['startedAtDeviceMs'] as int?,
        stoppedAtMs: j['stoppedAtMs'] as int?,
        endReason: j['endReason'] as String?,
        segments: [
          for (final s in j['segments'] as List) SegmentRecord.fromJson((s as Map).cast()),
        ],
        peer: j['peer'] == null ? null : PeerRecord.fromJson((j['peer'] as Map).cast()),
      );

  final String recordingId;
  final String gameId;
  final DeviceRole role;
  final DeviceIdentity device;
  final int createdAtMs;
  VideoInfo? video;
  int? startedAtDeviceMs;
  int? stoppedAtMs;

  /// Why recording ended if not by a normal stop (error / interruption).
  String? endReason;
  final List<SegmentRecord> segments;
  PeerRecord? peer;

  bool get stopped => stoppedAtMs != null;

  Map<String, Object?> toJson() => {
        'recordingId': recordingId,
        'gameId': gameId,
        'role': role.name,
        'device': device.toJson(),
        'createdAtMs': createdAtMs,
        'video': video?.toJson(),
        'startedAtDeviceMs': startedAtDeviceMs,
        'stoppedAtMs': stoppedAtMs,
        'endReason': endReason,
        'segments': [for (final s in segments) s.toJson()],
        'peer': peer?.toJson(),
      };
}

/// Main's view of Secondary for one recording.
class PeerRecord {
  PeerRecord({
    required this.device,
    this.video,
    this.clock,
    this.startedAtDeviceMs,
    this.expectedSegments,
    Map<int, SegmentRecord>? segments,
  }) : segments = segments ?? {};

  factory PeerRecord.fromJson(Map<String, Object?> j) => PeerRecord(
        device: DeviceIdentity.fromJson((j['device'] as Map).cast()),
        video: j['video'] == null ? null : VideoInfo.fromJson((j['video'] as Map).cast()),
        clock: j['clock'] == null ? null : ClockEstimate.fromJson((j['clock'] as Map).cast()),
        startedAtDeviceMs: j['startedAtDeviceMs'] as int?,
        expectedSegments: j['expectedSegments'] as int?,
        segments: {
          for (final s in j['segments'] as List)
            (s as Map)['index'] as int: SegmentRecord.fromJson(s.cast()),
        },
      );

  final DeviceIdentity device;
  VideoInfo? video;
  ClockEstimate? clock;
  int? startedAtDeviceMs;

  /// Known once Secondary reports `stopped`.
  int? expectedSegments;
  final Map<int, SegmentRecord> segments;

  bool get complete =>
      expectedSegments != null && segments.length >= expectedSegments!;

  Map<String, Object?> toJson() => {
        'device': device.toJson(),
        'video': video?.toJson(),
        'clock': clock?.toJson(),
        'startedAtDeviceMs': startedAtDeviceMs,
        'expectedSegments': expectedSegments,
        'segments': [
          for (final i in segments.keys.toList()..sort()) segments[i]!.toJson(),
        ],
      };
}
