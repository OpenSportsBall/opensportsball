// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';
import 'package:test/test.dart';

final a = Uint8List.fromList(List.generate(100000, (i) => i % 251));
final b = Uint8List.fromList(List.generate(70000, (i) => (i * 7) % 253));
String hex(List<int> x) => sha256.convert(x).toString();

/// A footage server: serves [files] by path, honours Range, refuses links
/// signed before [validFrom].
class FakeCdn {
  FakeCdn(this.files);
  final Map<String, Uint8List> files;
  final requests = <http.BaseRequest>[];
  int linkVersion = 1;
  int validFrom = 1;
  int linksAsked = 0;
  bool expireAfterManifest = false;
  String? manifestOverride;

  String get manifest => jsonEncode({
        'devices': [
          {
            'segments': [
              for (final e in files.entries) {'objectKey': e.key, 'bytes': e.value.length, 'sha256': hex(e.value)}
            ]
          }
        ]
      });

  Future<DownloadLinks> links({String status = 'ready', Map<String, String>? sha}) async {
    linksAsked++;
    return DownloadLinks(
      status: status,
      expiresAt: DateTime.now().add(const Duration(hours: 12)),
      manifestUrl: Uri.parse('https://cdn.test/manifest.json?v=$linkVersion'),
      files: [
        for (final e in files.entries)
          FootageFile(
            deviceId: e.key.split('/')[0],
            fileName: e.key.split('/')[1],
            bytes: e.value.length,
            sha256: sha == null ? hex(e.value) : sha[e.key],
            url: Uri.parse('https://cdn.test/${e.key}?v=$linkVersion'),
          )
      ],
    );
  }

  http.Client get client => MockClient.streaming((req, _) async {
        requests.add(req);
        final v = int.parse(req.url.queryParameters['v']!);
        if (v < validFrom) return http.StreamedResponse(Stream.value(utf8.encode('expired')), 403);
        if (req.url.path == '/manifest.json') {
          if (expireAfterManifest) validFrom = 2;
          return http.StreamedResponse(Stream.value(utf8.encode(manifestOverride ?? manifest)), 200);
        }
        final body = files[req.url.path.substring(1)]!;
        final range = req.headers['Range'];
        if (range != null) {
          final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          return http.StreamedResponse(Stream.value(body.sublist(from)), 206);
        }
        // In pieces, like a real body.
        return http.StreamedResponse(Stream.fromIterable([body.sublist(0, 30000), body.sublist(30000)]), 200);
      });
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('osb_dl'));
  tearDown(() async => dir.delete(recursive: true));

  test('downloads the manifest and each segment at its objectKey, then skips them', () async {
    final cdn = FakeCdn({'main/main_000.mp4': a, 'sec/sec_000.mp4': b});
    final d = FootageDownloader(folder: dir, links: cdn.links, client: cdn.client);
    final seen = <DownloadProgress>[];
    await d.run(onProgress: seen.add);
    expect(await File('${dir.path}/main/main_000.mp4').readAsBytes(), a);
    expect(await File('${dir.path}/sec/sec_000.mp4').readAsBytes(), b);
    expect(jsonDecode(await File('${dir.path}/manifest.json').readAsString()), isA<Map>());
    expect(seen.last.doneBytes, a.length + b.length);
    expect(seen.last.filesDone, 2);

    expect(await FootageDownloader.isComplete(dir), isTrue);
    await File('${dir.path}/sec/sec_000.mp4').writeAsBytes([1, 2, 3]);
    expect(await FootageDownloader.isComplete(dir), isFalse);
    await File('${dir.path}/sec/sec_000.mp4').writeAsBytes(b);
    cdn.requests.clear();
    await FootageDownloader(folder: dir, links: cdn.links, client: cdn.client).run();
    expect(cdn.requests.map((r) => r.url.path), ['/manifest.json']);
  });

  test('with maxSegments, fetches only the first segments of each phone and trims the manifest', () async {
    final c = Uint8List.fromList(List.generate(30000, (i) => (i * 3) % 251));
    final cdn = FakeCdn({'main/main_000.mp4': a, 'main/main_001.mp4': c, 'sec/sec_000.mp4': b, 'sec/sec_001.mp4': c});
    // The fake manifest lists segments in order: give them indexes.
    final m = jsonDecode(cdn.manifest) as Map;
    final segs = (m['devices'] as List).first['segments'] as List;
    m['devices'] = [
      {
        'segments': [
          for (final s in segs)
            if ((s['objectKey'] as String).startsWith('main/')) s
        ]
      },
      {
        'segments': [
          for (final s in segs)
            if ((s['objectKey'] as String).startsWith('sec/')) s
        ]
      },
    ];
    for (final d in m['devices'] as List) {
      for (final s in d['segments'] as List) {
        s['index'] = (s['objectKey'] as String).endsWith('_000.mp4') ? 0 : 1;
      }
    }
    cdn.manifestOverride = jsonEncode(m);
    await FootageDownloader(folder: dir, links: cdn.links, client: cdn.client, maxSegments: 1).run();
    expect(cdn.requests.where((r) => r.url.path.endsWith('.mp4')).map((r) => r.url.path).toSet(),
        {'/main/main_000.mp4', '/sec/sec_000.mp4'});
    final local = jsonDecode(await File('${dir.path}/manifest.json').readAsString()) as Map;
    expect([
      for (final d in local['devices'] as List)
        for (final s in d['segments'] as List) s['objectKey']
    ], [
      'main/main_000.mp4',
      'sec/sec_000.mp4'
    ]);
    expect(await FootageDownloader.isComplete(dir), isTrue);
  });

  test('resumes a partial file with a range request', () async {
    final cdn = FakeCdn({'main/main_000.mp4': a});
    await Directory('${dir.path}/main').create();
    await File('${dir.path}/main/main_000.mp4.part').writeAsBytes(a.sublist(0, 40000));
    await FootageDownloader(folder: dir, links: cdn.links, client: cdn.client).run();
    final seg = cdn.requests.firstWhere((r) => r.url.path.endsWith('.mp4'));
    expect(seg.headers['Range'], 'bytes=40000-');
    expect(await File('${dir.path}/main/main_000.mp4').readAsBytes(), a);
  });

  test('accepts a file already there when its SHA-256 matches', () async {
    final cdn = FakeCdn({'main/main_000.mp4': a});
    await Directory('${dir.path}/main').create();
    await File('${dir.path}/main/main_000.mp4').writeAsBytes(a);
    await FootageDownloader(folder: dir, links: cdn.links, client: cdn.client).run();
    expect(cdn.requests.where((r) => r.url.path.endsWith('.mp4')), isEmpty);
  });

  test('deletes a file whose SHA-256 differs, so the next run fetches it again', () async {
    final cdn = FakeCdn({'main/main_000.mp4': a});
    final d = FootageDownloader(
        folder: dir, links: () => cdn.links(sha: {'main/main_000.mp4': '0' * 64}), client: cdn.client);
    await expectLater(d.run(), throwsA(isA<FootageCorrupt>()));
    expect(File('${dir.path}/main/main_000.mp4').existsSync(), isFalse);
  });

  test('asks for fresh links when the footage server refuses old ones', () async {
    final cdn = FakeCdn({'main/main_000.mp4': a})..expireAfterManifest = true;
    Future<DownloadLinks> links() async {
      if (cdn.linksAsked == 1) cdn.linkVersion = 2; // the second answer has newer links
      return cdn.links();
    }

    await FootageDownloader(folder: dir, links: links, client: cdn.client).run();
    expect(await File('${dir.path}/main/main_000.mp4').readAsBytes(), a);
    final segs = cdn.requests.where((r) => r.url.path.endsWith('.mp4')).map((r) => r.url.queryParameters['v']);
    expect(segs, ['1', '2']);
  });

  test('refuses a recording that is still uploading, and odd file names', () async {
    final cdn = FakeCdn({'main/main_000.mp4': a});
    expect(FootageDownloader(folder: dir, links: () => cdn.links(status: 'uploading'), client: cdn.client).run(),
        throwsA(isA<OsbException>()));
    Future<DownloadLinks> bad() async => DownloadLinks(
          status: 'ready',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          manifestUrl: Uri.parse('https://cdn.test/manifest.json?v=1'),
          files: [FootageFile(deviceId: '..', fileName: 'x.mp4', bytes: 1, url: Uri.parse('https://cdn.test/x?v=1'))],
        );
    expect(FootageDownloader(folder: dir, links: bad, client: cdn.client).run(), throwsA(isA<OsbException>()));
  });
}
