// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// The API's people routes (docs/API.md) with a signed-in session's token:
/// games, recordings and footage download links.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sign_in.dart';
import 'site.dart';

/// Where a session's tokens are kept between launches (the Keychain, in
/// the apps).
abstract interface class TokenStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class MemoryTokenStore implements TokenStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

/// The session's sign-in has ended (refresh refused or no refresh token):
/// people have to sign in again.
class SignedOut implements Exception {
  const SignedOut();
  @override
  String toString() => 'Signed out. Sign in again.';
}

/// A signed-in person: the site's config and their tokens, refreshed
/// before they expire.
class Session {
  Session({
    required this.config,
    required Tokens tokens,
    required this.clientId,
    required this.client,
    required this.store,
    DateTime Function()? now,
  })  : _tokens = tokens,
        _now = now ?? DateTime.now;

  final SiteConfig config;
  final String clientId;
  final http.Client client;
  final TokenStore store;
  final DateTime Function() _now;
  Tokens _tokens;
  Future<Tokens>? _refreshing;

  Tokens get tokens => _tokens;
  String? get email => _tokens.email;
  String? get accountId => _tokens.accountId;

  /// The saved session, or null.
  static Future<Session?> restore(TokenStore store, http.Client client, {DateTime Function()? now}) async {
    final raw = await store.read();
    if (raw == null) return null;
    try {
      final j = (jsonDecode(raw) as Map).cast<String, Object?>();
      return Session(
        config: SiteConfig.fromJson(j['siteUrl'] as String, (j['config'] as Map).cast()),
        clientId: j['clientId'] as String,
        tokens: Tokens.fromJson((j['tokens'] as Map).cast()),
        client: client,
        store: store,
        now: now,
      );
    } on Object {
      await store.delete();
      return null;
    }
  }

  Future<void> save() => store.write(jsonEncode({
        'siteUrl': config.siteUrl,
        'config': config.toJson(),
        'clientId': clientId,
        'tokens': _tokens.toJson(),
      }));

  Future<void> signOut() => store.delete();

  /// A fresh access token. Throws [SignedOut] or [OsbException].
  Future<String> accessToken() async {
    if (_tokens.freshAt(_now())) return _tokens.accessToken;
    final refresh = _tokens.refreshToken;
    if (refresh == null) throw const SignedOut();
    _refreshing ??= () async {
      try {
        return await requestTokens(client, config.cognitoDomain,
            {'grant_type': 'refresh_token', 'client_id': clientId, 'refresh_token': refresh},
            now: _now);
      } finally {
        _refreshing = null;
      }
    }();
    try {
      _tokens = await _refreshing!;
    } on OsbException catch (e) {
      if (e.status == 400 || e.status == 401) throw const SignedOut();
      rethrow;
    }
    await save();
    return _tokens.accessToken;
  }

  /// Calls the API. Throws [SignedOut] or [OsbException] for any status
  /// but 2xx.
  Future<Object?> call(String method, String path, {Object? body}) async {
    final token = await accessToken();
    final req = http.Request(method, apiUri(config.apiUrl, path))..headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await send(() async => http.Response.fromStream(await client.send(req)));
    if (res.statusCode == 401) throw const SignedOut();
    if (res.statusCode < 200 || res.statusCode > 299) {
      throw OsbException('The server refused (${res.statusCode}${serverMessage(res)}).', status: res.statusCode);
    }
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  Future<List<GameSummary>> games() async {
    final j = (await call('GET', '/games') as Map).cast<String, Object?>();
    return [for (final g in j['games'] as List) GameSummary.fromJson((g as Map).cast())];
  }

  Future<Game> game(String gameId) async => Game.fromJson((await call('GET', '/games/$gameId') as Map).cast());

  Future<DownloadLinks> downloads(String gameId, String recordingId) async =>
      DownloadLinks.fromJson((await call('POST', '/games/$gameId/recordings/$recordingId/downloads') as Map).cast());
}

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// One line of `GET /games`.
class GameSummary {
  const GameSummary(
      {required this.gameId, required this.createdAt, this.recordedAt, this.recordingCount = 0, this.status});
  final String gameId;
  final DateTime createdAt;
  final DateTime? recordedAt;
  final int recordingCount;

  /// The least-finished status of its recordings (`ready` when all are).
  final String? status;

  DateTime get when => recordedAt ?? createdAt;

  factory GameSummary.fromJson(Map<String, Object?> j) => GameSummary(
        gameId: j['gameId'] as String,
        createdAt: _date(j['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        recordedAt: _date(j['recordedAt']),
        recordingCount: (j['recordingCount'] as num?)?.toInt() ?? 0,
        status: j['status'] as String?,
      );
}

/// `GET /games/{gameId}`.
class Game {
  const Game({required this.gameId, required this.recordings, this.recordedAt});
  final String gameId;
  final DateTime? recordedAt;
  final List<Recording> recordings;

  factory Game.fromJson(Map<String, Object?> j) => Game(
        gameId: j['gameId'] as String,
        recordedAt: _date(j['recordedAt']),
        recordings: [for (final r in (j['recordings'] as List? ?? [])) Recording.fromJson((r as Map).cast())],
      );
}

class Recording {
  const Recording({required this.recordingId, required this.status, this.recordedAt, this.devices = const []});
  final String recordingId;
  final String status;
  final DateTime? recordedAt;
  final List<RecordingDevice> devices;

  bool get ready => status == 'ready';

  /// Bytes the phones said they'd upload (null while unknown).
  int? get expectedBytes {
    var total = 0;
    for (final d in devices) {
      if (d.expectedBytes == null) return null;
      total += d.expectedBytes!;
    }
    return total;
  }

  factory Recording.fromJson(Map<String, Object?> j) => Recording(
        recordingId: j['recordingId'] as String,
        status: j['status'] as String? ?? 'waiting_for_manifest',
        recordedAt: _date(j['recordedAt']),
        devices: [for (final d in (j['devices'] as List? ?? [])) RecordingDevice.fromJson((d as Map).cast())],
      );
}

class RecordingDevice {
  const RecordingDevice({required this.deviceId, this.role, this.model, this.expectedBytes, this.uploadedBytes});
  final String deviceId;
  final String? role;
  final String? model;
  final int? expectedBytes;
  final int? uploadedBytes;

  factory RecordingDevice.fromJson(Map<String, Object?> j) => RecordingDevice(
        deviceId: j['deviceId'] as String,
        role: j['role'] as String?,
        model: j['model'] as String?,
        expectedBytes: (j['expectedBytes'] as num?)?.toInt(),
        uploadedBytes: (j['uploadedBytes'] as num?)?.toInt(),
      );
}

/// `POST /games/{gameId}/recordings/{recordingId}/downloads`: signed links,
/// good for 12 hours.
class DownloadLinks {
  const DownloadLinks({
    required this.status,
    required this.expiresAt,
    required this.files,
    this.manifestUrl,
  });
  final String status;
  final DateTime expiresAt;
  final Uri? manifestUrl;
  final List<FootageFile> files;

  factory DownloadLinks.fromJson(Map<String, Object?> j) => DownloadLinks(
        status: j['status'] as String,
        expiresAt: DateTime.parse(j['expiresAt'] as String),
        manifestUrl: j['manifestUrl'] is String ? Uri.parse(j['manifestUrl'] as String) : null,
        files: [for (final f in j['files'] as List) FootageFile.fromJson((f as Map).cast())],
      );
}

class FootageFile {
  const FootageFile(
      {required this.deviceId, required this.fileName, required this.bytes, required this.url, this.sha256});
  final String deviceId;
  final String fileName;
  final int bytes;
  final String? sha256;
  final Uri url;

  /// Where the engine expects it: the manifest's objectKey.
  String get objectKey => '$deviceId/$fileName';

  factory FootageFile.fromJson(Map<String, Object?> j) => FootageFile(
        deviceId: j['deviceId'] as String,
        fileName: j['fileName'] as String,
        bytes: (j['bytes'] as num).toInt(),
        sha256: j['sha256'] as String?,
        url: Uri.parse(j['url'] as String),
      );
}
