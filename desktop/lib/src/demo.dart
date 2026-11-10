// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// For development: a stand-in for the website, the API and the footage
/// server, serving one recording already on this Mac (a folder with its
/// merged manifest.json and segments, as footagestore.py fetch leaves it).
/// The app then runs for real: sign-in is skipped, but the games list, the
/// download (ranges, checks), the engine and the checks all do their work.
///
///     OSB_DEMO_RECORDING=/path/to/rec  [OSB_DEMO_SEGMENTS=4]  flutter run -d macos
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';

const _site = 'https://demo.opensportsball.invalid';
const _api = 'https://api.demo.opensportsball.invalid';
const _cdn = 'https://cdn.demo.opensportsball.invalid';

/// The demo session, when OSB_DEMO_RECORDING names a recording folder.
Session? demoSession() {
  final dir = Platform.environment['OSB_DEMO_RECORDING'];
  if (dir == null || dir.isEmpty) return null;
  final keep = int.tryParse(Platform.environment['OSB_DEMO_SEGMENTS'] ?? '') ?? 4;
  final manifest = (jsonDecode(File('$dir/manifest.json').readAsStringSync()) as Map).cast<String, Object?>();
  // Only the first [keep] segments of each phone: quicker to try.
  for (final d in manifest['devices'] as List) {
    final segs = (d as Map)['segments'] as List;
    d['segments'] = segs.take(keep).toList();
  }
  final gameId = manifest['gameId'] as String;
  final recordingId = (manifest['sessionId'] as String?) ?? gameId;
  final devices = [for (final d in manifest['devices'] as List) (d as Map).cast<String, Object?>()];
  int bytesOf(Map<String, Object?> d) =>
      (d['segments'] as List).fold<int>(0, (a, s) => a + ((s as Map)['bytes'] as int));
  final recordedAt = manifest['createdAt'] as String;

  Future<http.StreamedResponse> json(Object body, [int status = 200]) async => http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(body))),
    status,
    headers: {'content-type': 'application/json'},
  );

  final client = MockClient.streaming((req, _) async {
    final u = req.url.toString();
    final path = req.url.path;
    if (u.startsWith(_api)) {
      if (req.method == 'GET' && path == '/games') {
        return json({
          'games': [
            {
              'gameId': gameId,
              'createdAt': recordedAt,
              'recordedAt': recordedAt,
              'recordingCount': 1,
              'status': 'ready',
            },
          ],
        });
      }
      if (req.method == 'GET' && path == '/games/$gameId') {
        return json({
          'gameId': gameId,
          'createdAt': recordedAt,
          'recordedAt': recordedAt,
          'recordings': [
            {
              'recordingId': recordingId,
              'createdAt': recordedAt,
              'recordedAt': recordedAt,
              'status': 'ready',
              'hasManifest': true,
              'devices': [
                for (final d in devices)
                  {
                    'deviceId': d['deviceId'],
                    'role': d['role'],
                    'model': d['model'],
                    'expectedSegments': (d['segments'] as List).length,
                    'uploadedSegments': (d['segments'] as List).length,
                    'expectedBytes': bytesOf(d),
                    'uploadedBytes': bytesOf(d),
                  },
              ],
            },
          ],
        });
      }
      if (req.method == 'POST' && path == '/games/$gameId/recordings/$recordingId/downloads') {
        final expires = DateTime.now().add(const Duration(hours: 12));
        return json({
          'gameId': gameId,
          'recordingId': recordingId,
          'status': 'ready',
          'expiresAt': expires.toUtc().toIso8601String(),
          'manifestUrl': '$_cdn/manifest.json',
          'files': [
            for (final d in devices)
              for (final s in (d['segments'] as List).cast<Map>())
                {
                  'deviceId': d['deviceId'],
                  'fileName': (s['objectKey'] as String).split('/').last,
                  'bytes': s['bytes'],
                  'sha256': s['sha256'],
                  'url': '$_cdn/${s['objectKey']}',
                },
          ],
        });
      }
      return json({'error': 'not_found', 'message': 'No such route in the demo.'}, 404);
    }
    if (u.startsWith(_cdn)) {
      if (path == '/manifest.json') return json(manifest);
      final f = File('$dir$path');
      if (!f.existsSync()) return http.StreamedResponse(const Stream.empty(), 404);
      final length = f.lengthSync();
      final m = RegExp(r'bytes=(\d+)-').firstMatch(req.headers['Range'] ?? req.headers['range'] ?? '');
      final from = m == null ? 0 : int.parse(m.group(1)!);
      return http.StreamedResponse(f.openRead(from), m == null ? 200 : 206, contentLength: length - from);
    }
    return http.StreamedResponse(const Stream.empty(), 404);
  });

  return Session(
    config: const SiteConfig(siteUrl: _site, apiUrl: _api, cognitoDomain: _site, desktopClientId: 'demo'),
    clientId: 'demo',
    client: client,
    store: MemoryTokenStore(),
    tokens: Tokens(
      // A token-shaped string whose claims name a demo account.
      accessToken: 'demo.${base64Url.encode(utf8.encode(jsonEncode({'sub': 'demo'}))).replaceAll('=', '')}.demo',
      idToken: 'demo.${base64Url.encode(utf8.encode(jsonEncode({'email': 'demo@local'}))).replaceAll('=', '')}.demo',
      expiresAt: DateTime.now().add(const Duration(days: 365)),
    ),
  );
}
