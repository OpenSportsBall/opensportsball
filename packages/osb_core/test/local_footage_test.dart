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

final a = Uint8List.fromList(List.generate(40000, (i) => i % 251));
final b = Uint8List.fromList(List.generate(30000, (i) => (i * 7) % 253));
String hex(List<int> x) => sha256.convert(x).toString();

Map<String, Object?> seg(String device, int i, Uint8List data) => {
      'index': i,
      'objectKey': '$device/${device}_00$i.mp4',
      'bytes': data.length,
      'sha256': hex(data),
      'startedAtDeviceMs': 1794000000000 + i * 600000,
      'durationMs': 600000,
    };

Map<String, Object?> device(String id, String role, String model, [List<Map<String, Object?>>? segments]) =>
    {'deviceId': id, 'role': role, 'model': model, 'platform': 'android', if (segments != null) 'segments': segments};

/// Main's manifest as the phone writes it: both phones, Main's segments.
Map<String, Object?> mainManifest({bool listsSecond = true}) => {
      'schemaVersion': 1,
      'gameId': 'g1',
      'sessionId': 'r1',
      'createdAt': '2026-11-11T04:15:00Z',
      'devices': [
        device('mmm', 'main', 'Pixel 11', [seg('mmm', 0, a), seg('mmm', 1, b)]),
        if (listsSecond) device('sss', 'secondary', 'iPhone18,1'),
      ],
    };

Map<String, Object?> report() => {
      ...device('sss', 'secondary', 'iPhone18,1', [seg('sss', 0, b)]),
      'orientation': {'uprightRotationDeg': 180, 'rollDeg': 0.5, 'pitchDeg': -20},
    };

void main() {
  late Directory tmp, mainPhone, secondPhone, game;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('osb_local');
    // As copied off each phone: its document beside its segments.
    mainPhone = Directory('${tmp.path}/from-pixel/g1/r1')..createSync(recursive: true);
    File('${mainPhone.path}/manifest.json').writeAsStringSync(jsonEncode(mainManifest()));
    File('${mainPhone.path}/recording.json').writeAsStringSync(jsonEncode({'gameId': 'g1', 'recordingId': 'r1'}));
    File('${mainPhone.path}/mmm_000.mp4').writeAsBytesSync(a);
    File('${mainPhone.path}/mmm_001.mp4').writeAsBytesSync(b);
    secondPhone = Directory('${tmp.path}/from-iphone')..createSync();
    File('${secondPhone.path}/report.json').writeAsStringSync(jsonEncode(report()));
    File('${secondPhone.path}/recording.json').writeAsStringSync(jsonEncode({'gameId': 'g1', 'recordingId': 'r1'}));
    File('${secondPhone.path}/sss_000.mp4').writeAsBytesSync(b);
    game = Directory('${tmp.path}/games/one');
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('two phones\' folders become the folder the engine reads, and the originals are left alone', () async {
    // The folder above the phone's <gameId>/<recordingId> is fine too.
    final imp = FootageImport(folder: game, sources: [Directory('${tmp.path}/from-pixel'), secondPhone]);
    expect(imp.sources.gameId, 'g1');
    expect(imp.sources.recordingId, 'r1');
    final seen = <DownloadProgress>[];
    expect(await imp.copy(onProgress: seen.add), isEmpty);
    expect(seen.last.doneBytes, a.length + 2 * b.length);
    expect(seen.last.filesDone, 3);
    expect(await FootageDownloader.isComplete(game), isFalse); // no manifest yet
    await imp.finish();
    expect(await FootageDownloader.isComplete(game), isTrue);
    expect(File('${game.path}/mmm/mmm_001.mp4').readAsBytesSync(), b);
    expect(File('${game.path}/sss/sss_000.mp4').readAsBytesSync(), b);
    expect(File('${mainPhone.path}/mmm_000.mp4').existsSync(), isTrue);

    final m = (jsonDecode(File('${game.path}/manifest.json').readAsStringSync()) as Map).cast<String, Object?>();
    final second = (m['devices'] as List)[1] as Map;
    expect((second['segments'] as List).single['objectKey'], 'sss/sss_000.mp4');
    expect((second['orientation'] as Map)['uprightRotationDeg'], 180); // the phone's own report wins
    final rec = manifestRecording(m);
    expect(rec.recordingId, 'r1');
    expect(rec.expectedBytes, a.length + 2 * b.length);
    expect(rec.devices.map((d) => d.model), ['Pixel 11', 'iPhone18,1']);
    expect(manifestWhen(m), DateTime.fromMillisecondsSinceEpoch(1794000000000));

    // Again: nothing to copy, and a folder put together this way is itself a source.
    expect(await FootageImport(folder: game, sources: [mainPhone, secondPhone]).copy(), isEmpty);
    final again = FootageImport(folder: Directory('${tmp.path}/games/two'), sources: [game]);
    expect(await again.copy(), isEmpty);
    await again.finish();
    expect(await FootageDownloader.isComplete(again.folder), isTrue);
  });

  test('one phone alone says which phone is missing', () {
    expect(
      () => FootageImport(folder: game, sources: [mainPhone]).merged,
      throwsA(isA<PhoneMissing>()
          .having((e) => e.role, 'role', 'secondary')
          .having((e) => '$e', 'message', contains('the iPhone18,1'))),
    );
    expect(
      () => FootageImport(folder: game, sources: [secondPhone]).merged,
      throwsA(isA<PhoneMissing>().having((e) => e.role, 'role', 'main')),
    );
  });

  test('a second phone the main phone never listed is added from its report', () async {
    File('${mainPhone.path}/manifest.json').writeAsStringSync(jsonEncode(mainManifest(listsSecond: false)));
    final imp = FootageImport(folder: game, sources: [mainPhone, secondPhone]);
    expect([for (final d in imp.merged['devices'] as List) (d as Map)['role']], ['main', 'secondary']);
  });

  test('a file that is not what its phone recorded is refused, and another recording\'s folder', () async {
    File('${secondPhone.path}/sss_000.mp4').writeAsBytesSync(b.sublist(0, 100));
    await expectLater(
      FootageImport(folder: game, sources: [mainPhone, secondPhone]).copy(),
      throwsA(isA<OsbException>().having((e) => e.message, 'message', contains('not the size its phone recorded'))),
    );
    File('${secondPhone.path}/sss_000.mp4').writeAsBytesSync(Uint8List(b.length));
    await expectLater(
      FootageImport(folder: game, sources: [mainPhone, secondPhone]).copy(),
      throwsA(isA<OsbException>().having((e) => e.message, 'message', contains('is damaged'))),
    );
    expect(File('${game.path}/sss/sss_000.mp4').existsSync(), isFalse);

    File('${secondPhone.path}/recording.json').writeAsStringSync(jsonEncode({'gameId': 'g2', 'recordingId': 'r2'}));
    expect(
      () => FootageImport(folder: game, sources: [mainPhone, secondPhone]),
      throwsA(isA<OsbException>().having((e) => e.message, 'message', contains('more than one recording'))),
    );
    expect(
      () => FootageImport(folder: game, sources: [secondPhone], manifest: mainManifest()).merged,
      throwsA(isA<OsbException>().having((e) => e.message, 'message', contains('another recording'))),
    );
  });

  test('what the account has is downloaded, the missing phone comes from disk', () async {
    // Main uploaded; the second phone never did: its folder is on this computer.
    final imp = FootageImport(folder: game, sources: [secondPhone], manifest: mainManifest());
    final missing = await imp.copy();
    expect(missing, {'mmm/mmm_000.mp4', 'mmm/mmm_001.mp4'});
    await expectLater(imp.finish(), throwsA(isA<OsbException>()));

    final files = {'mmm/mmm_000.mp4': a, 'mmm/mmm_001.mp4': b};
    final asked = <String>[];
    final client = MockClient.streaming((req, _) async {
      asked.add(req.url.path);
      return http.StreamedResponse(Stream.value(files[req.url.path.substring(1)]!), 200);
    });
    Future<DownloadLinks> links() async => DownloadLinks(
          status: 'uploading', // never ready: one phone's files aren't in the account
          expiresAt: DateTime.now().add(const Duration(hours: 12)),
          files: [
            for (final e in files.entries)
              FootageFile(
                deviceId: 'mmm',
                fileName: e.key.split('/').last,
                bytes: e.value.length,
                sha256: hex(e.value),
                url: Uri.parse('https://cdn.test/${e.key}'),
              ),
          ],
        );
    await FootageDownloader(folder: game, links: links, client: client, only: missing).run();
    expect(asked, unorderedEquals(['/mmm/mmm_000.mp4', '/mmm/mmm_001.mp4'])); // no manifest asked for
    await imp.finish();
    expect(await FootageDownloader.isComplete(game), isTrue);

    await expectLater(
      FootageDownloader(folder: game, links: links, client: client, only: {'sss/sss_009.mp4'}).run(),
      throwsA(isA<OsbException>().having((e) => e.message, 'message', contains('not in the account'))),
    );
  });

  test('the links say what the phones reported, and a ticket makes its page link', () {
    final l = DownloadLinks.fromJson({
      'status': 'uploading',
      'expiresAt': '2026-11-12T00:00:00Z',
      'manifestUrl': null,
      'files': <Object>[],
      'manifest': mainManifest(),
      'reports': [report()],
    });
    expect(l.manifest!['sessionId'], 'r1');
    expect(l.reports.single['deviceId'], 'sss');
    final t = GameTicket.fromJson({'ticket': 'osbg_abc', 'expiresAt': '2026-11-12T00:00:00Z'});
    expect(t.pageUrl('https://opensportsball.com/'), 'https://opensportsball.com/grant#osbg_abc');
  });
}
