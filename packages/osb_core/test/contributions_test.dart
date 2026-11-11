// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory rec;
  late List<String> calls;
  late Map<String, List<int>> stored;
  late Set<String> live;
  var nextId = 0;
  var failPut = -1; // which PUT fails, counting down; -1: none

  Session session() => Session(
        config: const SiteConfig(
            siteUrl: 'https://x.test', apiUrl: 'https://api.x.test', cognitoDomain: 'https://l.x.test'),
        clientId: 'c',
        store: MemoryTokenStore(),
        tokens: Tokens(accessToken: 'a', expiresAt: DateTime(2100)),
        client: MockClient((req) async {
          final p = req.url.path;
          calls.add('${req.method} ${req.url.host}$p');
          if (req.url.host == 's3.test') {
            if (failPut >= 0 && failPut-- == 0) return http.Response('', 403);
            // The link was signed for this checksum: S3 refuses other bytes.
            expect(req.headers['x-amz-checksum-sha256'], base64.encode(sha256.convert(req.bodyBytes).bytes));
            stored[p] = req.bodyBytes;
            return http.Response('', 200);
          }
          expect(req.headers['Authorization'], 'Bearer a');
          if (req.method == 'POST' && p == '/contributions') {
            final b = (jsonDecode(req.body) as Map).cast<String, Object?>();
            expect(b['consentVersion'], 'share-v1');
            expect(b['gameId'], 'g1');
            expect(b['recordingId'], 'r1');
            final doc = (b['contribution'] as Map).cast<String, Object?>();
            final id = 'c${++nextId}';
            live.add(id);
            return http.Response(
                jsonEncode({
                  'contributionId': id,
                  'status': 'uploading',
                  'uploads': [
                    for (final f in (doc['files'] as List).cast<Map>())
                      {
                        'path': f['path'],
                        'url': 'https://s3.test/$id/${f['path']}',
                        'headers': {
                          'x-amz-checksum-sha256': base64.encode([
                            for (var i = 0; i < 64; i += 2)
                              int.parse((f['sha256'] as String).substring(i, i + 2), radix: 16)
                          ]),
                          'content-length': '${f['bytes']}',
                        },
                      }
                  ],
                }),
                201);
          }
          if (req.method == 'POST' && p.endsWith('/complete')) return http.Response('{"status":"complete"}', 200);
          if (req.method == 'DELETE') {
            final id = p.split('/').last;
            return live.remove(id) ? http.Response('', 204) : http.Response('{"error":"not_found"}', 404);
          }
          if (req.method == 'GET' && p == '/contributions') {
            return http.Response(
                jsonEncode({
                  'contributions': [
                    for (final id in live)
                      {
                        'contributionId': id,
                        'gameId': 'g1',
                        'recordingId': 'r1',
                        'kind': 'ball',
                        'name': 'ball-1',
                        'status': 'complete',
                        'files': 2,
                        'bytes': 9,
                        'createdAt': '2026-11-10T20:00:00Z'
                      }
                  ]
                }),
                200);
          }
          return http.Response('', 500);
        }),
      );

  Future<void> list(String name, Map<String, String> files, {Object? summary}) async {
    final out = <Map<String, Object?>>[];
    for (final f in files.entries) {
      final file = File('${rec.path}/${f.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(f.value);
      out.add({'path': f.key, 'bytes': f.value.length, 'sha256': sha256.convert(utf8.encode(f.value)).toString()});
    }
    final l = File('${rec.path}/engine/share/$name.json');
    await l.parent.create(recursive: true);
    await l.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'name': name,
      'kind': name.split('-').first,
      'createdAt': DateTime.now().toIso8601String(),
      'summary': summary ?? {},
      'files': out,
    }));
  }

  Future<List<String>> sendAll(Iterable<String> names) =>
      sendShared(session: session(), recording: rec, gameId: 'g1', recordingId: 'r1', names: names);

  setUp(() async {
    rec = await Directory.systemTemp.createTemp('osb_share');
    calls = [];
    stored = {};
    live = {};
    nextId = 0;
    failPut = -1;
  });
  tearDown(() => rec.delete(recursive: true));

  test('sends each agreed result once, file by file, and again only when it changed', () async {
    await list('pitch', {'pitch/background.png': 'PNG', 'pitch/pitch.json': '{}'});
    await list('ball-1', {'engine/labels/ball-1/set.json': '{"a":1}'}, summary: {'labelled': 2});
    final progress = <SendProgress>[];
    expect(
        await sendShared(
            session: session(),
            recording: rec,
            gameId: 'g1',
            recordingId: 'r1',
            names: ['pitch', 'kits', 'ball-1'], // kits: not listed, the user chose not to share them
            onProgress: progress.add),
        ['pitch', 'ball-1']);
    expect(utf8.decode(stored['/c1/pitch/background.png']!), 'PNG');
    expect(stored.keys, containsAll(['/c1/pitch/pitch.json', '/c2/engine/labels/ball-1/set.json']));
    expect(calls.where((c) => c.endsWith('/complete')), hasLength(2));
    expect(progress.last, (name: 'ball-1', filesDone: 1, files: 1));
    final record = await SentRecord.read(rec);
    expect(record.names, ['ball-1', 'pitch']);
    expect(record.idOf('pitch'), 'c1');

    // Listed again by the engine (a new createdAt), nothing changed: nothing is sent.
    await list('pitch', {'pitch/background.png': 'PNG', 'pitch/pitch.json': '{}'});
    calls.clear();
    expect(await sendAll(['pitch', 'ball-1']), isEmpty);
    expect(calls, isEmpty);

    // More ball labels: the set goes again and the older copy is withdrawn.
    await list('ball-1', {'engine/labels/ball-1/set.json': '{"a":2}'}, summary: {'labelled': 5});
    expect(await sendAll(['pitch', 'ball-1']), ['ball-1']);
    expect(live, {'c1', 'c3'});
    expect((await SentRecord.read(rec)).idOf('ball-1'), 'c3');
    expect((await session().contributions()).map((c) => c.id), ['c1', 'c3']);
  });

  test('a failed file leaves it unsent, to be sent whole next time', () async {
    await list('kits', {'engine/crops/a.jpg': 'A', 'engine/crops/b.jpg': 'B'});
    failPut = 1;
    await expectLater(sendAll(['kits']), throwsA(isA<OsbException>().having((e) => e.status, 'status', 403)));
    expect((await SentRecord.read(rec)).names, isEmpty);
    expect(await sendAll(['kits']), ['kits']);
    expect((await SentRecord.read(rec)).idOf('kits'), 'c2');
  });

  test('withdrawing deletes what was sent and stops sending from this game', () async {
    await list('pitch', {'pitch/pitch.json': '{}'});
    await list('kits', {'engine/crops/a.jpg': 'A'});
    await sendAll(['pitch', 'kits']);
    live.remove('c2'); // already withdrawn on the website: still counts
    await withdrawShared(session: session(), recording: rec);
    expect(live, isEmpty);
    final record = await SentRecord.read(rec);
    expect(record.names, isEmpty);
    expect(record.stopped, isTrue);
    calls.clear();
    expect(await sendAll(['pitch', 'kits']), isEmpty);
    expect(calls, isEmpty);
    await resumeSharing(rec);
    expect(await sendAll(['pitch', 'kits']), ['pitch', 'kits']);
  });

  test('a list naming a file outside the folder is refused', () async {
    await list('pitch', {'pitch/pitch.json': '{}'});
    final l = File('${rec.path}/engine/share/pitch.json');
    await l.writeAsString((await l.readAsString()).replaceAll('pitch/pitch.json', '../other/secret.json'));
    await expectLater(sendAll(['pitch']), throwsA(isA<OsbException>()));
    expect(calls, isEmpty);
  });
}
