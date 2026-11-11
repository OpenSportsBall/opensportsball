// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Sending what a user agreed to share to improve the models (docs/API.md,
/// "Contributions"): the pitch map, the kit groups and the label sets, as
/// the engine lists them in `<recording>/engine/share/<name>.json`
/// (`osb-engine share`, shared/schemas/engine-contribution.schema.json).
/// Nothing here decides what is shared: the engine lists only what the
/// user's answers allow, and the caller only sends with the consent given.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'site.dart';

/// The consent wording the apps show before anything is sent
/// (shared/consent/share-v1.md); the API refuses others.
const shareConsentVersion = 'share-v1';

/// One contribution as the API lists it.
class Contribution {
  const Contribution({
    required this.id,
    required this.gameId,
    required this.recordingId,
    required this.kind,
    required this.name,
    required this.status,
    required this.files,
    required this.bytes,
    this.createdAt,
  });

  final String id;
  final String gameId;
  final String recordingId;

  /// `pitch`, `kits`, `ball` or `moments`.
  final String kind;

  /// `pitch`, `kits`, `ball-1`, ...
  final String name;

  /// `uploading` or `complete`.
  final String status;
  final int files;
  final int bytes;
  final DateTime? createdAt;

  factory Contribution.fromJson(Map<String, Object?> j) => Contribution(
        id: j['contributionId'] as String,
        gameId: j['gameId'] as String? ?? '',
        recordingId: j['recordingId'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        name: j['name'] as String? ?? '',
        status: j['status'] as String? ?? '',
        files: (j['files'] as num?)?.toInt() ?? 0,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
      );
}

/// The contributions routes.
extension ContributionsApi on Session {
  Future<List<Contribution>> contributions() async {
    final j = (await call('GET', '/contributions') as Map).cast<String, Object?>();
    return [for (final c in j['contributions'] as List) Contribution.fromJson((c as Map).cast())];
  }

  /// Withdraws one for good. One already gone counts as withdrawn.
  Future<void> withdrawContribution(String id) async {
    try {
      await call('DELETE', '/contributions/$id');
    } on OsbException catch (e) {
      if (e.status != 404) rethrow;
    }
  }
}

/// What has been sent from one recording, kept beside the engine's lists
/// (`engine/share/sent.json`) so nothing is sent twice and it can be
/// withdrawn.
class SentRecord {
  SentRecord._(this._file, this._sent, this.stopped);

  final File _file;
  final Map<String, Map<String, Object?>> _sent;

  /// The user withdrew this game's contributions: nothing more is sent
  /// from it until they share it again.
  bool stopped;

  static File fileIn(Directory recording) => File('${recording.path}/engine/share/sent.json');

  static Future<SentRecord> read(Directory recording) async {
    final f = fileIn(recording);
    Map<String, Object?> j = {};
    try {
      j = (jsonDecode(await f.readAsString()) as Map).cast();
    } on Object {
      // nothing sent yet
    }
    return SentRecord._(
      f,
      {for (final e in ((j['sent'] as Map?) ?? {}).entries) '${e.key}': (e.value as Map).cast()},
      j['stopped'] == true,
    );
  }

  /// Names sent and not withdrawn, e.g. `pitch`, `kits`, `ball-1`.
  List<String> get names => _sent.keys.toList()..sort();
  String? idOf(String name) => _sent[name]?['contributionId'] as String?;
  String? digestOf(String name) => _sent[name]?['digest'] as String?;
  List<String> get ids => [for (final n in names) idOf(n)!];

  void put(String name, String id, String digest) =>
      _sent[name] = {'contributionId': id, 'digest': digest, 'at': DateTime.now().toUtc().toIso8601String()};
  void remove(String name) => _sent.remove(name);

  Future<void> save() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert({'stopped': stopped, 'sent': _sent}));
    await tmp.rename(_file.path);
  }
}

/// What the engine's list says, without when it was written: the same
/// result listed again later has the same digest.
String shareDigest(Map<String, Object?> doc) => sha256
    .convert(utf8.encode(jsonEncode({'kind': doc['kind'], 'summary': doc['summary'], 'files': doc['files']})))
    .toString();

/// How far [sendShared] is.
typedef SendProgress = ({String name, int filesDone, int files});

/// Sends the engine's lists named [names] (`engine/share/<name>.json`)
/// that haven't been sent as they now stand. A result sent before and
/// changed since (more ball labels) is sent again and the older copy
/// withdrawn, so the project holds one of each. Returns the names sent.
/// Throws [SignedOut] or [OsbException]; what was sent before the failure
/// is recorded, and calling again carries on.
Future<List<String>> sendShared({
  required Session session,
  required Directory recording,
  required String gameId,
  required String recordingId,
  required Iterable<String> names,
  void Function(SendProgress)? onProgress,
}) async {
  final record = await SentRecord.read(recording);
  if (record.stopped) return const [];
  final done = <String>[];
  for (final name in names) {
    final listFile = File('${recording.path}/engine/share/$name.json');
    if (!await listFile.exists()) continue;
    final doc = (jsonDecode(await listFile.readAsString()) as Map).cast<String, Object?>();
    final digest = shareDigest(doc);
    if (record.digestOf(name) == digest) continue;
    final files = [for (final f in doc['files'] as List) (f as Map).cast<String, Object?>()];
    for (final f in files) {
      final p = f['path'] as String;
      if (p.startsWith('/') || p.split('/').contains('..')) {
        throw OsbException('The engine listed a file outside the game\'s folder ($p).');
      }
    }
    final started = (await session.call('POST', '/contributions', body: {
      'gameId': gameId,
      'recordingId': recordingId,
      'consentVersion': shareConsentVersion,
      'contribution': doc,
    }) as Map)
        .cast<String, Object?>();
    final id = started['contributionId'] as String;
    var n = 0;
    onProgress?.call((name: name, filesDone: 0, files: files.length));
    for (final u in (started['uploads'] as List).cast<Map>()) {
      final req = http.Request('PUT', Uri.parse(u['url'] as String))
        ..bodyBytes = await File('${recording.path}/${u['path']}').readAsBytes();
      for (final h in ((u['headers'] as Map?) ?? {}).entries) {
        // The length is the body's own; the checksum is what the link was signed for.
        if ('${h.key}'.toLowerCase() != 'content-length') req.headers['${h.key}'] = '${h.value}';
      }
      final res = await send(
        () async => http.Response.fromStream(await session.client.send(req)),
        timeout: const Duration(minutes: 10), // up to 50 MB on a home connection
      );
      if (res.statusCode < 200 || res.statusCode > 299) {
        throw OsbException('Sending ${u['path']} was refused (${res.statusCode}).', status: res.statusCode);
      }
      onProgress?.call((name: name, filesDone: ++n, files: files.length));
    }
    await session.call('POST', '/contributions/$id/complete');
    final older = record.idOf(name);
    record.put(name, id, digest);
    await record.save();
    if (older != null) await session.withdrawContribution(older);
    done.add(name);
  }
  return done;
}

/// Withdraws everything sent from [recording] and stops sending from it.
Future<void> withdrawShared({required Session session, required Directory recording}) async {
  final record = await SentRecord.read(recording);
  record.stopped = true;
  await record.save();
  for (final name in record.names) {
    await session.withdrawContribution(record.idOf(name)!);
    record.remove(name);
    await record.save();
  }
}

/// Lets a game whose contributions were withdrawn be shared again.
Future<void> resumeSharing(Directory recording) async {
  final record = await SentRecord.read(recording);
  record.stopped = false;
  await record.save();
}
