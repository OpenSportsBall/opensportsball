// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opensportsball/src/model.dart';
import 'package:opensportsball/src/role.dart';
import 'package:opensportsball/src/storage/store.dart';
import 'package:opensportsball/src/upload/network.dart';

const apiUrl = 'https://api.test';
const deviceToken = 'osbd_testtoken';
const accountId = 'acc-1';

/// A recording grant from another phone's account, for 'game-1'.
const grantToken = 'osbg_testgrant';
const grantAccountId = 'acc-main';

class FakeNetwork implements NetworkMonitor {
  FakeNetwork([this.kind = NetworkKind.unmetered]);
  NetworkKind kind;
  final _changes = StreamController<NetworkKind>.broadcast();

  void set(NetworkKind k) {
    kind = k;
    _changes.add(k);
  }

  @override
  Future<NetworkKind> current() async => kind;
  @override
  Stream<NetworkKind> get changes => _changes.stream;
}

class _ServerUpload {
  _ServerUpload(this.uploadId, this.bytes);
  final String uploadId;
  final int bytes;
  final parts = <int, Uint8List>{};
}

/// The API and S3 in one MockClient (docs/API.md).
class FakeBackend {
  FakeBackend({this.partSize = 128});

  final int partSize;
  final log = <String>[];
  final manifests = <String, Map<String, Object?>>{};

  /// Each phone's own segment list, by recordingId.
  final reports = <String, Map<String, Object?>>{};

  /// Final file contents, by `<recordingId>/<fileName>`, once completed.
  final files = <String, Uint8List>{};
  final _uploads = <String, _ServerUpload>{};
  var _nextId = 0;

  /// Reject the device token / the grant token with 401.
  bool unauthorized = false;
  bool grantRejected = false;

  /// The bearer token of each API call, in order.
  final tokens = <String>[];

  /// Each API call with its bearer token, in order.
  final calls = <(String, String)>[];

  /// Grant tickets issued (POST /grant-tickets) and how each was bound
  /// (POST /grants/redeem): ticket -> (gameId, deviceId).
  final ticketsIssued = <String>[];
  final redeemed = <String, (String, String)>{};

  /// Answer POST /grants/redeem with this status instead (e.g. 409).
  int? redeemStatus;

  /// Fail the next PUT of (fileName, part) with a network error.
  final failPut = <(String, int)>{};

  /// Answer the next PUT of (fileName, part) with 403 (expired URL).
  final expirePut = <(String, int)>{};

  /// Called before each S3 PUT is answered.
  void Function(String fileName, int part)? onPut;

  int putCount(String fileName, int part) =>
      log.where((l) => l == 'PUT s3 $fileName $part').length;

  int get putTotal => log.where((l) => l.startsWith('PUT s3')).length;

  late final http.Client client = MockClient(_handle);

  String _etag(Uint8List b) => '"${md5.convert(b)}"';

  Future<http.Response> _handle(http.Request req) async {
    if (req.url.host == 's3.test') return _s3(req);
    final path = req.url.path;
    log.add('${req.method} $path');
    final token = (req.headers['Authorization'] ?? '').replaceFirst('Bearer ', '');
    tokens.add(token);
    calls.add(('${req.method} $path', token));
    if (req.method == 'POST' && path == '/grants/redeem') return _redeem(req);
    final ok = (token == deviceToken && !unauthorized) ||
        (token == grantToken && !grantRejected) ||
        (redeemed.containsKey(token) && !grantRejected);
    if (!ok) return _json(401, {'error': 'unauthorized', 'message': 'bad token'});
    if (req.method == 'POST' && path == '/grant-tickets') {
      if (token != deviceToken) return _json(403, {'error': 'forbidden', 'message': 'device token only'});
      final count = (jsonDecode(req.body) as Map)['count'] as int;
      final expires = DateTime.now().toUtc().add(const Duration(days: 90)).toIso8601String();
      final fresh = [for (var i = 0; i < count; i++) 'osbg_ticket${ticketsIssued.length + i}'];
      ticketsIssued.addAll(fresh);
      return _json(201, {
        'tickets': [for (final t in fresh) {'ticket': t, 'expiresAt': expires}],
        'apiUrl': 'https://api.test',
        'accountId': accountId,
        'open': ticketsIssued.length - redeemed.length,
      });
    }
    final manifest = RegExp(r'^/games/([^/]+)/recordings/([^/]+)/manifest$').firstMatch(path);
    if (req.method == 'PUT' && manifest != null) {
      final body = (jsonDecode(req.body) as Map).cast<String, Object?>();
      if (body['gameId'] != manifest[1] || body['sessionId'] != manifest[2]) {
        return _json(400, {'error': 'bad_request', 'message': 'ids'});
      }
      manifests[manifest[2]!] = body;
      return _json(200, {'status': 'uploading', 'missing': []});
    }
    final report = RegExp(r'^/games/([^/]+)/recordings/([^/]+)/report$').firstMatch(path);
    if (req.method == 'PUT' && report != null) {
      reports[report[2]!] = (jsonDecode(req.body) as Map).cast<String, Object?>();
      return _json(200, {'status': 'uploading', 'missing': [], 'awaitingReports': []});
    }
    if (req.method == 'POST' && path == '/uploads') {
      final b = (jsonDecode(req.body) as Map).cast<String, Object?>();
      final name = '${b['recordingId']}/${b['fileName']}';
      if (files.containsKey(name)) return _json(200, {'alreadyUploaded': true});
      final bytes = b['bytes'] as int;
      final u = _uploads.putIfAbsent(name, () => _ServerUpload('up-${_nextId++}', bytes));
      final count = (bytes + partSize - 1) ~/ partSize;
      return _json(200, {
        'uploadId': u.uploadId,
        'partSizeBytes': partSize,
        'parts': [
          for (var n = 1; n <= count; n++)
            if (!u.parts.containsKey(n))
              {'partNumber': n, 'url': 'https://s3.test/${u.uploadId}/$name/$n?sig=x'},
        ],
        'completedParts': [
          for (final n in u.parts.keys.toList()..sort())
            {'partNumber': n, 'etag': _etag(u.parts[n]!)},
        ],
        'urlsExpireAt': DateTime.now().toUtc().add(const Duration(hours: 6)).toIso8601String(),
      });
    }
    if (req.method == 'POST' && path == '/uploads/complete') {
      final b = (jsonDecode(req.body) as Map).cast<String, Object?>();
      final name = '${b['recordingId']}/${b['fileName']}';
      final u = _uploads[name];
      if (u == null || u.uploadId != b['uploadId']) {
        return _json(400, {'error': 'bad_request', 'message': 'no such upload'});
      }
      final parts = (b['parts'] as List).cast<Map<String, Object?>>();
      final out = BytesBuilder();
      for (var i = 0; i < parts.length; i++) {
        final n = parts[i]['partNumber'] as int;
        final data = u.parts[n];
        if (n != i + 1 || data == null || parts[i]['etag'] != _etag(data)) {
          return _json(400, {'error': 'bad_request', 'message': 'bad part $n'});
        }
        out.add(data);
      }
      final all = out.takeBytes();
      if (all.length != u.bytes) return _json(400, {'error': 'bad_request', 'message': 'size'});
      files[name] = all;
      _uploads.remove(name);
      return _json(200, {'ok': true});
    }
    return _json(404, {'error': 'not_found', 'message': path});
  }

  http.Response _redeem(http.Request req) {
    if (redeemStatus != null) return _json(redeemStatus!, {'error': 'conflict', 'message': 'refused'});
    final b = (jsonDecode(req.body) as Map).cast<String, Object?>();
    final ticket = b['ticket'] as String, binding = (b['gameId'] as String, b['deviceId'] as String);
    if (!ticketsIssued.contains(ticket) && ticket != grantToken) {
      return _json(404, {'error': 'not_found', 'message': 'no such ticket'});
    }
    final existing = redeemed[ticket];
    if (existing != null && existing != binding) return _json(409, {'error': 'conflict', 'message': 'bound'});
    redeemed[ticket] = binding;
    return _json(200, {
      'grantToken': ticket,
      'apiUrl': 'https://api.test',
      'accountId': accountId,
      'gameId': binding.$1,
      'deviceId': binding.$2,
      'expiresAt': DateTime.now().toUtc().add(const Duration(days: 14)).toIso8601String(),
    });
  }

  http.Response _s3(http.Request req) {
    final seg = req.url.pathSegments; // uploadId, recordingId, fileName, part
    final name = '${seg[1]}/${seg[2]}', n = int.parse(seg[3]);
    log.add('PUT s3 ${seg[2]} $n');
    if (req.headers.containsKey('Authorization')) return http.Response('auth header sent', 400);
    onPut?.call(seg[2], n);
    if (failPut.remove((seg[2], n))) throw http.ClientException('connection reset');
    if (expirePut.remove((seg[2], n))) return http.Response('expired', 403);
    final u = _uploads[name];
    if (u == null || u.uploadId != seg[0]) return http.Response('NoSuchUpload', 404);
    u.parts[n] = req.bodyBytes;
    return http.Response('', 200, headers: {'etag': _etag(req.bodyBytes)});
  }

  http.Response _json(int code, Object body) =>
      http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json'});
}

/// Writes a stopped recording with segments of the given sizes, plus a
/// manifest when [manifest] is set (Main only).
Future<StoredRecording> writeRecording(
  AppStore store, {
  required String recordingId,
  required List<int> sizes,
  DeviceRole role = DeviceRole.main,
  bool manifest = true,
  int createdAtMs = 1000,
  bool stopped = true,
}) async {
  final dir = store.recordingDir('game-1', recordingId);
  await dir.create(recursive: true);
  final id = store.identity.deviceId;
  final segs = <SegmentRecord>[];
  for (var i = 0; i < sizes.length; i++) {
    final bytes = Uint8List.fromList(List.generate(sizes[i], (j) => (j * 7 + i) % 256));
    final name = '${id}_${i.toString().padLeft(3, '0')}.mp4';
    await File('${dir.path}/$name').writeAsBytes(bytes);
    segs.add(SegmentRecord(
      index: i,
      fileName: name,
      bytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
      startedAtDeviceMs: 1000 + i * 60000,
      durationMs: 60000,
    ));
  }
  final rec = LocalRecording(
    recordingId: recordingId,
    gameId: 'game-1',
    role: role,
    device: store.identity,
    createdAtMs: createdAtMs,
    video: const VideoInfo(
        width: 3840, height: 2160, nominalFps: 30, codec: 'hevc', lens: 'ultrawide', bitrateBps: 1),
    startedAtDeviceMs: 1000,
    stoppedAtMs: stopped ? 2000 : null,
    segments: segs,
  );
  await store.saveRecording(rec);
  if (manifest && role == DeviceRole.main) {
    await store.saveManifest(rec, {
      'schemaVersion': 1,
      'gameId': 'game-1',
      'sessionId': recordingId,
      'createdAt': '2026-10-01T00:00:00Z',
      'devices': [],
    });
  }
  return (await store.listRecordings()).firstWhere((r) => r.recording.recordingId == recordingId);
}
