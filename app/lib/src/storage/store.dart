// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Local persistence: device identity, settings, and recordings on disk.
///
/// Layout under [AppStore.recordingsRoot]:
///
/// ```
/// <gameId>/<recordingId>/
///   <deviceId>_000.mp4, <deviceId>_001.mp4, ...
///   recording.json     this phone's record (LocalRecording)
///   manifest.json      Main only, once it stops: both phones, Main's segments
///   report.json        Secondary only, once it stops: its own segments
///   power.csv          battery / thermal / storage once a minute while
///                      recording (PowerLog), for field tests
///   upload.json        upload progress (UploadState); never written by
///                      the recorder, so the two never race
/// ```
///
/// Recordings live where the user can copy them off during testing: the
/// app's Documents folder on iOS (visible in Finder / Files) and the app's
/// external files folder on Android (visible over USB).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../model.dart';
import '../role.dart';
import 'manifest.dart';

class AppStore {
  AppStore._(this._supportDir, this.recordingsRoot, this.identity, this._settings,
      this._uploadSettings);

  @visibleForTesting
  AppStore.forTest({
    required Directory supportDir,
    required this.recordingsRoot,
    required this.identity,
    RecordingSettings settings = const RecordingSettings(),
    UploadSettings uploadSettings = const UploadSettings(),
  })  : _supportDir = supportDir,
        _settings = settings,
        _uploadSettings = uploadSettings;

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
    final upload = await _readJson(File('${support.path}/upload_settings.json'));
    return AppStore._(
      support,
      root,
      identity,
      settings == null ? const RecordingSettings() : RecordingSettings.fromJson(settings),
      upload == null ? const UploadSettings() : UploadSettings.fromJson(upload),
    );
  }

  final Directory _supportDir;
  final Directory recordingsRoot;
  final DeviceIdentity identity;
  RecordingSettings _settings;
  UploadSettings _uploadSettings;

  RecordingSettings get settings => _settings;

  Future<void> saveSettings(RecordingSettings s) async {
    _settings = s;
    await _writeJson(File('${_supportDir.path}/settings.json'), s.toJson());
  }

  /// This phone's upload preferences. Kept apart from [settings], which
  /// Main sends to Secondary.
  UploadSettings get uploadSettings => _uploadSettings;

  Future<void> saveUploadSettings(UploadSettings s) async {
    _uploadSettings = s;
    await _writeJson(File('${_supportDir.path}/upload_settings.json'), s.toJson());
  }

  /// Contents of `upload.json` for a recording, or null if none yet.
  Future<Map<String, Object?>?> readUploadJson(Directory recordingDir) =>
      _readJson(File('${recordingDir.path}/upload.json'));

  Future<void> writeUploadJson(Directory recordingDir, Map<String, Object?> json) =>
      _writeJson(File('${recordingDir.path}/upload.json'), json);

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

  /// Writes this phone's upload document (Main's manifest or another
  /// phone's report) if the recording has stopped and it is missing.
  /// Returns whether it exists now.
  Future<bool> ensureUploadDocument(StoredRecording s) async {
    final file = File('${s.dir.path}/${s.documentName}');
    if (await file.exists()) return true;
    final r = s.recording;
    final doc = r.role == DeviceRole.main ? buildManifest(r) : buildReport(r);
    if (doc == null) return false;
    await _writeJson(file, doc);
    return true;
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
        final recording = LocalRecording.fromJson(json);
        out.add(StoredRecording(
          dir: rec,
          recording: recording,
          hasDocument: await File('${rec.path}/${uploadDocumentName(recording.role)}').exists(),
        ));
      }
    }
    out.sort((a, b) => b.recording.createdAtMs.compareTo(a.recording.createdAtMs));
    return out;
  }

  /// Finishes recordings the app was killed in the middle of, so their
  /// footage still uploads: adds segment files that reached disk but were
  /// never hashed, then marks the recording stopped. Call at startup, when
  /// nothing can be recording.
  Future<int> recoverInterruptedRecordings() async {
    var recovered = 0;
    for (final r in await listRecordings()) {
      final rec = r.recording;
      if (rec.stopped) continue;
      final known = {for (final s in rec.segments) s.fileName};
      final prefix = '${rec.device.deviceId}_';
      final orphans = <File>[
        await for (final f in r.dir.list())
          if (f is File) f,
      ].where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith(prefix) && name.endsWith('.mp4') && !known.contains(name);
      }).toList();
      for (final f in orphans) {
        final bytes = await f.length();
        // iOS creates the next segment file ahead of time; skip empty ones.
        if (bytes < 1024) continue;
        final name = f.uri.pathSegments.last;
        final index = int.tryParse(name.substring(prefix.length, name.length - 4));
        if (index == null) continue;
        final path = f.path;
        rec.segments.add(SegmentRecord(
          index: index,
          fileName: name,
          bytes: bytes,
          sha256: await Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString()),
          // Unknown after a crash; processing reads timing from the file.
          startedAtDeviceMs: 0,
          durationMs: 0,
        ));
      }
      rec.segments.sort((a, b) => a.index.compareTo(b.index));
      rec.stoppedAtMs = DateTime.now().millisecondsSinceEpoch;
      rec.endReason ??= 'app closed while recording';
      await saveRecording(rec);
      recovered++;
    }
    return recovered;
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

/// `manifest.json` on Main, `report.json` on other phones.
String uploadDocumentName(DeviceRole role) => role == DeviceRole.main ? 'manifest.json' : 'report.json';

class StoredRecording {
  const StoredRecording({
    required this.dir,
    required this.recording,
    required this.hasDocument,
  });

  final Directory dir;
  final LocalRecording recording;

  /// Whether [documentName] has been written.
  final bool hasDocument;

  String get documentName => uploadDocumentName(recording.role);

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
    this.sport,
    this.video,
    this.orientation,
    this.startedAtDeviceMs,
    this.stoppedAtMs,
    this.endReason,
    List<SegmentRecord>? segments,
    List<SettingsLock>? locks,
    this.peer,
  })  : segments = segments ?? [],
        locks = locks ?? [];

  factory LocalRecording.fromJson(Map<String, Object?> j) => LocalRecording(
        recordingId: j['recordingId'] as String,
        gameId: j['gameId'] as String,
        role: DeviceRole.values.byName(j['role'] as String),
        device: DeviceIdentity.fromJson((j['device'] as Map).cast()),
        createdAtMs: j['createdAtMs'] as int,
        sport: Sport.fromName(j['sport'] as String?),
        video: j['video'] == null ? null : VideoInfo.fromJson((j['video'] as Map).cast()),
        orientation: j['orientation'] == null
            ? null
            : MountOrientation.fromJson((j['orientation'] as Map).cast()),
        startedAtDeviceMs: j['startedAtDeviceMs'] as int?,
        stoppedAtMs: j['stoppedAtMs'] as int?,
        endReason: j['endReason'] as String?,
        segments: [
          for (final s in j['segments'] as List) SegmentRecord.fromJson((s as Map).cast()),
        ],
        locks: [
          for (final l in (j['locks'] as List?) ?? const []) SettingsLock.fromJson((l as Map).cast()),
        ],
        peer: j['peer'] == null ? null : PeerRecord.fromJson((j['peer'] as Map).cast()),
      );

  final String recordingId;
  final String gameId;
  final DeviceRole role;
  final DeviceIdentity device;
  final int createdAtMs;

  /// The sport setting when recording started; null in recordings from
  /// before it existed.
  final Sport? sport;
  VideoInfo? video;

  /// Measured when recording starts, then again at each settings lock
  /// (the phone is on the mount by then); null if the phone couldn't tell.
  MountOrientation? orientation;
  int? startedAtDeviceMs;
  int? stoppedAtMs;

  /// Why recording ended if not by a normal stop (error / interruption).
  String? endReason;
  final List<SegmentRecord> segments;

  /// Each time white balance and focus were locked, in order.
  final List<SettingsLock> locks;
  PeerRecord? peer;

  bool get stopped => stoppedAtMs != null;

  Map<String, Object?> toJson() => {
        'recordingId': recordingId,
        'gameId': gameId,
        'role': role.name,
        'device': device.toJson(),
        'createdAtMs': createdAtMs,
        'sport': sport?.name,
        'video': video?.toJson(),
        'orientation': orientation?.toJson(),
        'startedAtDeviceMs': startedAtDeviceMs,
        'stoppedAtMs': stoppedAtMs,
        'endReason': endReason,
        'segments': [for (final s in segments) s.toJson()],
        'locks': [for (final l in locks) l.toJson()],
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
    this.granted = false,
    Map<int, SegmentRecord>? segments,
  }) : segments = segments ?? {};

  factory PeerRecord.fromJson(Map<String, Object?> j) => PeerRecord(
        device: DeviceIdentity.fromJson((j['device'] as Map).cast()),
        video: j['video'] == null ? null : VideoInfo.fromJson((j['video'] as Map).cast()),
        clock: j['clock'] == null ? null : ClockEstimate.fromJson((j['clock'] as Map).cast()),
        startedAtDeviceMs: j['startedAtDeviceMs'] as int?,
        expectedSegments: j['expectedSegments'] as int?,
        // Recordings from before grants: Secondary was on Main's account.
        granted: j['granted'] as bool? ?? true,
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

  /// Secondary confirmed it has Main's recording grant for this game, so
  /// it can upload its part into Main's account.
  bool granted;
  final Map<int, SegmentRecord> segments;

  bool get complete =>
      expectedSegments != null && segments.length >= expectedSegments!;

  Map<String, Object?> toJson() => {
        'device': device.toJson(),
        'video': video?.toJson(),
        'clock': clock?.toJson(),
        'startedAtDeviceMs': startedAtDeviceMs,
        'expectedSegments': expectedSegments,
        'granted': granted,
        'segments': [
          for (final i in segments.keys.toList()..sort()) segments[i]!.toJson(),
        ],
      };
}
