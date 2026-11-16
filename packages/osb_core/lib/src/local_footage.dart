// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// A game's footage from video already on this computer: the folders
/// copied off the phones (app/lib/src/storage/store.dart: Main's
/// `manifest.json` or another phone's `report.json`, beside that phone's
/// `<deviceId>_NNN.mp4` segments), put together as the folder the engine
/// reads (download.dart: the merged manifest.json and each segment at its
/// objectKey, `<deviceId>/<fileName>`).
///
/// The manifest is merged as the API does it (api/src/lib/manifest.ts:
/// mergeManifest). Each file is checked against the size and SHA-256 its
/// phone recorded before it counts. The chosen folders are only read: the
/// segments are copied (on the same disk as an APFS clone, which takes no
/// time or room).
library;

import 'dart:convert';
import 'dart:io';

import 'api.dart';
import 'download.dart';
import 'site.dart';

/// The folders hold no video from one of the two phones the engine needs.
class PhoneMissing implements Exception {
  const PhoneMissing(this.role, {this.model});

  /// `main` or `secondary`.
  final String role;

  /// What the missing phone is, when the other phone's manifest says.
  final String? model;

  @override
  String toString() => role == 'main'
      ? 'The main phone’s video isn’t in that folder: its manifest.json lists both phones.'
      : 'The second phone’s video${model == null ? '' : ' (the $model)'} isn’t in that folder.';
}

Map<String, Object?>? _readMap(File f) {
  try {
    final j = jsonDecode(f.readAsStringSync());
    return j is Map ? j.cast() : null;
  } on Object {
    return null;
  }
}

List<Map<String, Object?>> _devices(Map<String, Object?> manifest) =>
    [for (final d in (manifest['devices'] as List? ?? [])) (d as Map).cast()];

List<Map<String, Object?>> _segments(Map<String, Object?> device) =>
    [for (final s in (device['segments'] as List? ?? [])) (s as Map).cast()];

/// Main's manifest with every phone's segments filled in from its own
/// report, which also wins for what only that phone knows (how it was held,
/// when it locked its camera settings). A second phone Main's manifest
/// leaves out is added from its report.
Map<String, Object?> mergeManifest(Map<String, Object?> manifest, List<Map<String, Object?>> reports) {
  final byId = {for (final r in reports) r['deviceId']: r};
  var devices = _devices(manifest);
  if (!devices.any((d) => d['role'] == 'secondary')) {
    final late = reports.where((r) => r['role'] == 'secondary').firstOrNull;
    if (late != null) devices = [...devices, late];
  }
  return {
    ...manifest,
    'devices': [
      for (final d in devices)
        {
          ...d,
          if (byId[d['deviceId']]?['orientation'] != null) 'orientation': byId[d['deviceId']]!['orientation'],
          if (byId[d['deviceId']]?['settingsLocks'] != null) 'settingsLocks': byId[d['deviceId']]!['settingsLocks'],
          'segments': byId[d['deviceId']]?['segments'] ?? d['segments'] ?? [],
        },
    ],
  };
}

/// Throws [PhoneMissing] unless [merged] has a main and a second phone,
/// each with segments: the engine stitches the two views.
void checkBothPhones(Map<String, Object?> merged) {
  for (final role in ['main', 'secondary']) {
    final d = _devices(merged).where((d) => d['role'] == role).firstOrNull;
    if (d == null || _segments(d).isEmpty) throw PhoneMissing(role, model: d?['model'] as String?);
  }
}

/// When the recording started: its earliest segment, else when the
/// manifest was written.
DateTime? manifestWhen(Map<String, Object?> manifest) {
  final starts = [
    for (final d in _devices(manifest))
      for (final s in _segments(d))
        if (s['startedAtDeviceMs'] is num) (s['startedAtDeviceMs'] as num).toInt(),
  ]..sort();
  if (starts.isNotEmpty) return DateTime.fromMillisecondsSinceEpoch(starts.first);
  return DateTime.tryParse('${manifest['createdAt']}');
}

/// The manifest's recording as the API would describe it (`GET /games/{id}`):
/// each phone and the bytes it recorded.
Recording manifestRecording(Map<String, Object?> manifest, {String status = 'ready'}) => Recording(
      recordingId: '${manifest['sessionId']}',
      status: status,
      recordedAt: manifestWhen(manifest),
      devices: [
        for (final d in _devices(manifest))
          RecordingDevice(
            deviceId: '${d['deviceId']}',
            role: d['role'] as String?,
            model: d['model'] as String?,
            expectedBytes: _segments(d).fold<int>(0, (a, s) => a + (s['bytes'] as num).toInt()),
          ),
      ],
    );

/// What the chosen folders hold.
class FootageSources {
  FootageSources._(this.folders, this.manifest, this.reports, this.gameId, this.recordingId);

  /// The folders with footage: the chosen ones, or those inside them (up to
  /// two levels down: the phone app's `<gameId>/<recordingId>`).
  final List<Directory> folders;

  /// Main's manifest (or a merged one), when a folder has it.
  final Map<String, Object?>? manifest;

  /// The other phones' reports of their own segments.
  final List<Map<String, Object?>> reports;

  /// Which game and recording, when a manifest or a phone's recording.json
  /// says.
  final String? gameId;
  final String? recordingId;

  static bool _hasFootage(Directory d) =>
      File('${d.path}/manifest.json').existsSync() || File('${d.path}/report.json').existsSync();

  static List<Directory> _expand(Directory chosen, [int depth = 2]) {
    if (_hasFootage(chosen) || depth == 0) return [chosen];
    try {
      final inside = [
        for (final e in chosen.listSync(followLinks: false))
          if (e is Directory) ..._expand(e, depth - 1).where(_hasFootage),
      ];
      return inside.isEmpty ? [chosen] : inside;
    } on FileSystemException {
      return [chosen];
    }
  }

  /// Throws [OsbException] when the folders hold more than one recording.
  static FootageSources read(List<Directory> chosen) {
    final folders = [for (final c in chosen) ..._expand(c)];
    Map<String, Object?>? manifest;
    final reports = <Map<String, Object?>>[];
    final ids = <(String?, String)>{}; // (game, recording)
    for (final d in folders) {
      final m = _readMap(File('${d.path}/manifest.json'));
      if (m != null && m['devices'] is List) {
        // A merged manifest (both phones' segments) is the better base.
        if (manifest == null || _devices(m).every((d) => _segments(d).isNotEmpty)) manifest = m;
        if (m['sessionId'] is String) ids.add((m['gameId'] as String?, m['sessionId'] as String));
      }
      final r = _readMap(File('${d.path}/report.json'));
      if (r != null && r['deviceId'] is String && r['segments'] is List) reports.add(r);
      final rec = _readMap(File('${d.path}/recording.json'));
      if (rec != null && rec['recordingId'] is String) {
        ids.add((rec['gameId'] as String?, rec['recordingId'] as String));
      }
    }
    if ({for (final i in ids) i.$2}.length > 1) {
      throw const OsbException('Those folders hold more than one recording. Choose one game’s folders.');
    }
    return FootageSources._(
      folders,
      manifest,
      reports,
      ids.map((i) => i.$1).whereType<String>().firstOrNull,
      ids.firstOrNull?.$2,
    );
  }

  /// The segment [objectKey] (`<deviceId>/<fileName>`) in the folders: as a
  /// phone keeps it (`<fileName>`) or as a recording folder does.
  File? find(String objectKey) {
    final name = objectKey.split('/').last;
    for (final d in folders) {
      for (final f in [File('${d.path}/$objectKey'), File('${d.path}/$name')]) {
        if (f.existsSync()) return f;
      }
    }
    return null;
  }
}

/// Puts a recording together in [folder] from the [sources] folders, and
/// from what the account already has ([manifest] and [reports], with the
/// files the caller downloads between [copy] and [finish]).
class FootageImport {
  FootageImport({required this.folder, required List<Directory> sources, this.manifest, this.reports = const []})
      : sources = FootageSources.read(sources);

  /// The recording folder (the engine job's `recording`).
  final Directory folder;
  final FootageSources sources;

  /// The account's: Main's manifest (null when it never arrived) and the
  /// other phones' reports.
  final Map<String, Object?>? manifest;
  final List<Map<String, Object?>> reports;

  bool _stop = false;

  /// Stops after the current file; what is already in place stays.
  void stop() => _stop = true;

  /// The manifest of the whole recording: the account's or the folders',
  /// with every phone's segments. Throws [PhoneMissing] when a phone's
  /// video is in neither, [OsbException] when the folders are another
  /// recording's or list a file name that isn't a plain one.
  late final Map<String, Object?> merged = _merge();

  Map<String, Object?> _merge() {
    final base = manifest ?? sources.manifest;
    if (base == null) throw const PhoneMissing('main');
    final id = sources.recordingId;
    if (id != null && base['sessionId'] != null && id != base['sessionId']) {
      throw const OsbException('That folder holds another recording, not this game’s.');
    }
    // The account's reports first: a phone's own folder wins over them.
    final m = mergeManifest(base, [...reports, ...sources.reports]);
    checkBothPhones(m);
    for (final d in _devices(m)) {
      for (final s in _segments(d)) {
        final parts = '${s['objectKey']}'.split('/');
        if (parts.length != 2 || parts[0] != d['deviceId'] || !parts.every(isPlainName) || s['bytes'] is! num) {
          throw OsbException('The manifest lists an unexpected file (${s['objectKey']}).');
        }
      }
    }
    return m;
  }

  List<Map<String, Object?>> get _all => [for (final d in _devices(merged)) ..._segments(d)];

  /// Every segment's bytes.
  int get totalBytes => _all.fold<int>(0, (a, s) => a + (s['bytes'] as num).toInt());

  File get _verifiedFile => File('${folder.path}/.downloads.json');

  Future<Map<String, Object?>> _verified() async => _readMap(_verifiedFile) ?? {};

  Future<void> _saveVerified(Map<String, Object?> verified) async {
    final tmp = File('${_verifiedFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(verified));
    await tmp.rename(_verifiedFile.path);
  }

  /// Whether [dest] is segment [s], checked: as recorded when it was put
  /// there, or by its SHA-256 now.
  Future<bool> _inPlace(File dest, Map<String, Object?> s, Map<String, Object?> verified) async {
    if (!await dest.exists()) return false;
    final st = await dest.stat();
    final key = s['objectKey'] as String, v = verified[key];
    if (st.size != s['bytes']) return false;
    if (v is Map && v['bytes'] == s['bytes'] && v['modified'] == st.modified.millisecondsSinceEpoch) return true;
    final sha = s['sha256'] as String?;
    if (sha == null || await sha256OfFile(dest) != sha.toLowerCase()) return false;
    verified[key] = {'bytes': s['bytes'], 'modified': st.modified.millisecondsSinceEpoch, 'sha256': sha};
    return true;
  }

  /// Copies in every segment the folders have and [folder] hasn't, checking
  /// each. Returns the objectKeys in neither (for the caller to download).
  /// Throws [DownloadStopped], or [OsbException] for a file that isn't
  /// what its phone recorded.
  Future<Set<String>> copy({void Function(DownloadProgress)? onProgress}) async {
    _stop = false;
    final all = _all;
    await folder.create(recursive: true);
    final verified = await _verified();
    final total = totalBytes;
    var done = 0, filesDone = 0;
    final missing = <String>{};
    void report(String? current) => onProgress?.call(DownloadProgress(
        doneBytes: done, totalBytes: total, filesDone: filesDone, files: all.length, current: current));
    report(null);
    for (final s in all) {
      if (_stop) throw const DownloadStopped();
      final key = s['objectKey'] as String, bytes = (s['bytes'] as num).toInt();
      final dest = File('${folder.path}/$key');
      report(key);
      if (!await _inPlace(dest, s, verified)) {
        final src = sources.find(key);
        if (src == null) {
          missing.add(key);
          continue;
        }
        if (await src.length() != bytes) {
          throw OsbException('${src.path} is not the size its phone recorded: a copy that didn’t finish?');
        }
        await dest.parent.create(recursive: true);
        final part = File('${dest.path}.part');
        if (await part.exists()) await part.delete();
        await _copy(src, part);
        final sha = s['sha256'] as String?;
        if (sha != null && await sha256OfFile(part) != sha.toLowerCase()) {
          await part.delete();
          throw OsbException('${src.path} is damaged (its SHA-256 differs from what its phone recorded).');
        }
        await part.rename(dest.path);
        final st = await dest.stat();
        verified[key] = {'bytes': bytes, 'modified': st.modified.millisecondsSinceEpoch, 'sha256': sha};
      }
      await _saveVerified(verified);
      done += bytes;
      filesDone++;
      report(null);
    }
    return missing;
  }

  /// A clone where the disk can (APFS, same volume: no time, no room), else
  /// a copy.
  static Future<void> _copy(File src, File dest) async {
    if (Platform.isMacOS) {
      final r = await Process.run('/bin/cp', ['-c', src.path, dest.path]);
      if (r.exitCode == 0) return;
    }
    await src.copy(dest.path);
  }

  /// Writes the merged manifest.json, once every segment is in place: from
  /// then on the folder is a whole recording ([FootageDownloader.isComplete]).
  /// Throws [OsbException] naming a segment that is not.
  Future<void> finish() async {
    final verified = await _verified();
    for (final s in _all) {
      if (!await _inPlace(File('${folder.path}/${s['objectKey']}'), s, verified)) {
        throw OsbException('${s['objectKey']} is missing: it is in neither the folder chosen nor the account.');
      }
    }
    await _saveVerified(verified);
    final f = File('${folder.path}/manifest.json');
    final tmp = File('${f.path}.part');
    await tmp.writeAsString(jsonEncode(merged), flush: true);
    await tmp.rename(f.path);
  }
}
