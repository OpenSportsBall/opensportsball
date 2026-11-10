// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Downloading a recording's footage into the folder the engine reads: the
/// merged manifest.json and each segment at its objectKey
/// (`<deviceId>/<fileName>`), as footagestore.py fetch leaves it.
///
/// Each file goes to `<name>.part` first and resumes with a range request
/// after a stop, a lost connection or a quit; it is renamed only once its
/// size and SHA-256 match. Links last 12 hours, so fresh ones are asked
/// for when they are about to expire or a request is refused.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'site.dart';

typedef LinksSource = Future<DownloadLinks> Function();

class DownloadProgress {
  const DownloadProgress(
      {required this.doneBytes,
      required this.totalBytes,
      required this.filesDone,
      required this.files,
      this.current,
      this.bytesPerSecond});
  final int doneBytes;
  final int totalBytes;
  final int filesDone;
  final int files;
  final String? current;
  final double? bytesPerSecond;

  double get fraction => totalBytes == 0 ? 0 : doneBytes / totalBytes;
}

class DownloadStopped implements Exception {
  const DownloadStopped();
}

/// A file arrived but isn't what the phone recorded.
class FootageCorrupt implements Exception {
  const FootageCorrupt(this.objectKey);
  final String objectKey;
  @override
  String toString() => '$objectKey arrived damaged (its SHA-256 differs). It will be downloaded again.';
}

/// A name the server gave that is safe as one path part.
bool _plainName(String s) =>
    s.isNotEmpty && s != '.' && s != '..' && !s.contains('/') && !s.contains('\\') && !s.contains('\x00');

/// SHA-256 of a file, hex.
Future<String> sha256OfFile(File f) async => (await sha256.bind(f.openRead()).first).toString();

class FootageDownloader {
  FootageDownloader({
    required this.folder,
    required this.links,
    required this.client,
    this.parallel = 2,
    this.maxSegments,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The recording folder (the engine job's `recording`).
  final Directory folder;
  final LinksSource links;
  final http.Client client;
  final int parallel;

  /// For development: only the first this many segments (by index) of each
  /// phone, with the manifest trimmed to match, so the engine sees a short
  /// but complete recording. Null: all of it.
  final int? maxSegments;
  final DateTime Function() _now;

  bool _stop = false;
  DownloadLinks? _links;

  /// Whether [folder] already holds the manifest and every segment it
  /// lists, as a finished download left them (no network needed).
  static Future<bool> isComplete(Directory folder) async {
    try {
      final m = (jsonDecode(await File('${folder.path}/manifest.json').readAsString()) as Map).cast<String, Object?>();
      final v =
          (jsonDecode(await File('${folder.path}/.downloads.json').readAsString()) as Map).cast<String, Object?>();
      var segments = 0;
      for (final d in m['devices'] as List) {
        for (final s in ((d as Map)['segments'] as List? ?? [])) {
          segments++;
          final key = (s as Map)['objectKey'] as String;
          final got = v[key];
          final f = File('${folder.path}/$key');
          if (got is! Map || !f.existsSync() || f.lengthSync() != got['bytes'] || got['bytes'] != s['bytes']) {
            return false;
          }
        }
      }
      return segments > 0;
    } on Object {
      return false;
    }
  }

  /// Stops after the current reads; partial files are kept for resuming.
  void stop() => _stop = true;

  File get _verifiedFile => File('${folder.path}/.downloads.json');

  Future<Map<String, Object?>> _verified() async {
    try {
      return (jsonDecode(await _verifiedFile.readAsString()) as Map).cast();
    } on Object {
      return {};
    }
  }

  /// Fresh links (re-asked when within 30 minutes of expiring, or [force]).
  Future<DownloadLinks> _fresh({bool force = false}) async {
    final l = _links;
    if (!force && l != null && _now().add(const Duration(minutes: 30)).isBefore(l.expiresAt)) return l;
    return _links = await links();
  }

  /// Downloads whatever is missing. Throws [DownloadStopped],
  /// [OsbException] (refused, offline, not ready) or [FootageCorrupt] (the
  /// damaged file is deleted; running again fetches it anew).
  Future<void> run({void Function(DownloadProgress)? onProgress}) async {
    _stop = false;
    final l = await _fresh(force: true);
    if (l.status != 'ready' || l.manifestUrl == null) {
      throw const OsbException('This recording is still uploading. Try again once both phones have finished.');
    }
    for (final f in l.files) {
      if (!_plainName(f.deviceId) || !_plainName(f.fileName)) {
        throw OsbException('The server listed an unexpected file name (${f.objectKey}).');
      }
    }
    await folder.create(recursive: true);
    final manifestFile = File('${folder.path}/manifest.json');
    await _getSmall(l.manifestUrl!, manifestFile);
    var files = l.files;
    if (maxSegments != null) {
      final keep = await _trimManifest(manifestFile, maxSegments!);
      files = [
        for (final f in l.files)
          if (keep.contains(f.objectKey)) f
      ];
    }
    final manifestSha = _manifestHashes(await manifestFile.readAsString());

    final verified = await _verified();
    final total = files.fold<int>(0, (a, f) => a + f.bytes);
    var done = 0, filesDone = 0;
    final todo = <FootageFile>[];
    for (final f in files) {
      final dest = File('${folder.path}/${f.objectKey}');
      final v = verified[f.objectKey];
      if (await dest.exists()) {
        final st = await dest.stat();
        var ok = v is Map &&
            st.size == f.bytes &&
            v['bytes'] == f.bytes &&
            v['modified'] == st.modified.millisecondsSinceEpoch;
        // Already there from elsewhere (footagestore.py fetch, a copy): check it once.
        final expected = f.sha256 ?? manifestSha[f.objectKey];
        if (!ok && st.size == f.bytes && expected != null && await sha256OfFile(dest) == expected.toLowerCase()) {
          verified[f.objectKey] = {
            'bytes': f.bytes,
            'modified': st.modified.millisecondsSinceEpoch,
            'sha256': expected
          };
          ok = true;
        }
        if (ok) {
          done += f.bytes;
          filesDone++;
          continue;
        }
      }
      todo.add(f);
    }
    final started = _now();
    var startedDone = done;
    final inFlight = <String, int>{};
    void report(String? current) {
      final now = _now();
      final secs = now.difference(started).inMilliseconds / 1000;
      final got = done + inFlight.values.fold<int>(0, (a, b) => a + b);
      onProgress?.call(DownloadProgress(
        doneBytes: got,
        totalBytes: total,
        filesDone: filesDone,
        files: files.length,
        current: current,
        bytesPerSecond: secs > 2 ? (got - startedDone) / secs : null,
      ));
    }

    report(null);
    final queue = [...todo];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (_stop) throw const DownloadStopped();
        final f = queue.removeAt(0);
        final expected = f.sha256 ?? manifestSha[f.objectKey];
        final partBytes = await _getLarge(f, (n) {
          inFlight[f.objectKey] = n;
          report(f.objectKey);
        });
        startedDone += partBytes; // bytes that were already there don't count toward the speed
        inFlight.remove(f.objectKey);
        final dest = File('${folder.path}/${f.objectKey}');
        if (expected != null) {
          final got = await sha256OfFile(dest);
          if (got != expected.toLowerCase()) {
            await dest.delete();
            throw FootageCorrupt(f.objectKey);
          }
        }
        final st = await dest.stat();
        verified[f.objectKey] = {'bytes': f.bytes, 'modified': st.modified.millisecondsSinceEpoch, 'sha256': expected};
        await _verifiedFile.writeAsString(jsonEncode(verified));
        done += f.bytes;
        filesDone++;
        report(null);
      }
    }

    await _verifiedFile.writeAsString(jsonEncode(verified));
    Future<void> guarded() async {
      try {
        await worker();
      } on Object {
        _stop = true; // the other workers stop too; their .part files stay for resuming
        rethrow;
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) guarded()], eagerError: true);
  }

  /// Keeps the first [n] segment indexes in [manifest] (the same indexes
  /// on every phone) and returns the objectKeys kept.
  static Future<Set<String>> _trimManifest(File manifest, int n) async {
    final m = (jsonDecode(await manifest.readAsString()) as Map).cast<String, Object?>();
    final devices = [for (final d in m['devices'] as List) (d as Map).cast<String, Object?>()];
    int indexOf(Object? s) => ((s as Map)['index'] as num).toInt();
    final indexes = {
      for (final d in devices)
        for (final s in (d['segments'] as List? ?? [])) indexOf(s)
    }.toList()
      ..sort();
    final kept = indexes.take(n).toSet();
    final keys = <String>{};
    for (final d in devices) {
      final segs = [
        for (final s in (d['segments'] as List? ?? []))
          if (kept.contains(indexOf(s))) s
      ];
      d['segments'] = segs;
      keys.addAll([for (final s in segs) (s as Map)['objectKey'] as String]);
    }
    m['devices'] = devices;
    await manifest.writeAsString(jsonEncode(m));
    return keys;
  }

  Map<String, String> _manifestHashes(String manifest) {
    final out = <String, String>{};
    try {
      final m = (jsonDecode(manifest) as Map).cast<String, Object?>();
      for (final d in m['devices'] as List) {
        for (final s in ((d as Map)['segments'] as List? ?? [])) {
          final seg = (s as Map).cast<String, Object?>();
          if (seg['objectKey'] is String && seg['sha256'] is String) {
            out[seg['objectKey'] as String] = seg['sha256'] as String;
          }
        }
      }
    } on Object {
      // The engine checks the manifest itself; without hashes, only sizes are checked here.
    }
    return out;
  }

  Future<void> _getSmall(Uri url, File dest) async {
    final res = await send(() => client.get(url), timeout: const Duration(minutes: 2));
    if (res.statusCode != 200) {
      throw OsbException('Could not download the manifest (${res.statusCode}).', status: res.statusCode);
    }
    final tmp = File('${dest.path}.part');
    await tmp.writeAsBytes(res.bodyBytes, flush: true);
    await tmp.rename(dest.path);
  }

  /// Fetches one segment into place (resuming its .part), returning how
  /// many bytes were already there. [onBytes] gets the bytes this run has
  /// read so far.
  Future<int> _getLarge(FootageFile f, void Function(int) onBytes) async {
    final dest = File('${folder.path}/${f.objectKey}');
    await dest.parent.create(recursive: true);
    final part = File('${dest.path}.part');
    var have = await part.exists() ? await part.length() : 0;
    if (have > f.bytes) {
      await part.delete();
      have = 0;
    }
    final already = have;
    var refusals = 0, failures = 0;
    while (have < f.bytes) {
      if (_stop) throw const DownloadStopped();
      final file = (await _fresh()).files.firstWhere((x) => x.objectKey == f.objectKey,
          orElse: () => throw OsbException('${f.objectKey} is no longer listed on the server.'));
      final req = http.Request('GET', file.url);
      if (have > 0) req.headers['Range'] = 'bytes=$have-';
      http.StreamedResponse res;
      try {
        res = await client.send(req).timeout(const Duration(seconds: 60));
      } on Object catch (e) {
        if (++failures > 5) throw OsbException('Could not reach the footage server ($e).', offline: true);
        await Future<void>.delayed(Duration(seconds: 2 * failures));
        continue;
      }
      if (res.statusCode == 403 || res.statusCode == 401) {
        await res.stream.drain<void>();
        if (++refusals > 2) {
          throw OsbException('The footage server refused ${f.objectKey} (${res.statusCode}).', status: res.statusCode);
        }
        await _fresh(force: true);
        continue;
      }
      if (res.statusCode == 200 && have > 0) {
        have = 0; // the server ignored the range: start over
      } else if (res.statusCode != 200 && res.statusCode != 206) {
        await res.stream.drain<void>();
        if (++failures > 5) {
          throw OsbException('Could not download ${f.objectKey} (${res.statusCode}).', status: res.statusCode);
        }
        await Future<void>.delayed(Duration(seconds: 2 * failures));
        continue;
      }
      final sink = part.openWrite(mode: have == 0 ? FileMode.writeOnly : FileMode.append);
      try {
        await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          have += chunk.length;
          onBytes(have - already);
          if (_stop) break;
        }
      } on Object {
        if (++failures > 5) rethrow;
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (_stop) throw const DownloadStopped();
      failures = 0;
    }
    if (have != f.bytes) throw OsbException('${f.objectKey}: got $have bytes, expected ${f.bytes}.');
    await part.rename(dest.path);
    return already;
  }
}
