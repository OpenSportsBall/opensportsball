// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';
import 'package:test/test.dart';

String jwt(Map<String, Object?> claims) =>
    'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

const gameId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const otherGame = '22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const recId = '99999999-cccc-4ccc-8ccc-cccccccccccc';
final footage = {
  'main/main_000.mp4': Uint8List.fromList(List.generate(50000, (i) => i % 251)),
  'sec/sec_000.mp4': Uint8List.fromList(List.generate(40000, (i) => (i * 7) % 253)),
};

/// The website, Cognito, the API and the footage server in one.
class FakeService {
  String otherStatus = 'uploading';
  final asked = <String>[];
  Map<String, String>? tokenForm;

  http.Client get client => MockClient.streaming((req, body) async {
        final path = '${req.url.host}${req.url.path}';
        asked.add('${req.method} $path');
        http.StreamedResponse json(Object o, [int status = 200]) =>
            http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(o))), status);
        switch (path) {
          case 'osb.test/config.json':
            return json({
              'apiUrl': 'https://api.osb.test',
              'cognitoDomain': 'https://login.osb.test',
              'desktopClientId': 'desk',
            });
          case 'login.osb.test/oauth2/token':
            tokenForm = Uri.splitQueryString(await body.bytesToString());
            return json({
              'access_token': jwt({'sub': 'acct-1'}),
              'id_token': jwt({'email': 'coach@example.com'}),
              'refresh_token': 'r1',
              'expires_in': 3600,
            });
          case 'api.osb.test/games':
            if (req.headers['Authorization'] == null) return json({}, 401);
            return json({
              'games': [
                {'gameId': gameId, 'createdAt': '2026-10-15T16:23:00Z', 'recordingCount': 1, 'status': 'ready'},
                {'gameId': otherGame, 'createdAt': '2026-10-20T16:00:00Z', 'recordingCount': 1, 'status': otherStatus},
              ],
            });
          case 'api.osb.test/games/$gameId':
            return json({
              'gameId': gameId,
              'recordings': [
                {
                  'recordingId': recId,
                  'status': 'ready',
                  'devices': [
                    {'deviceId': 'main', 'role': 'main', 'model': 'Pixel 11', 'expectedBytes': 50000},
                    {'deviceId': 'sec', 'role': 'secondary', 'model': 'Pixel 11', 'expectedBytes': 40000},
                  ],
                },
              ],
            });
          case 'api.osb.test/games/$otherGame':
            return json({
              'gameId': otherGame,
              'recordings': [
                {'recordingId': recId, 'status': otherStatus, 'devices': []},
              ],
            });
          case 'api.osb.test/games/$gameId/recordings/$recId/downloads':
            return json({
              'status': 'ready',
              'expiresAt': DateTime.now().add(const Duration(hours: 12)).toUtc().toIso8601String(),
              'manifestUrl': 'https://cdn.test/manifest.json',
              'files': [
                for (final e in footage.entries)
                  {
                    'deviceId': e.key.split('/')[0],
                    'fileName': e.key.split('/')[1],
                    'bytes': e.value.length,
                    'sha256': sha256.convert(e.value).toString(),
                    'url': 'https://cdn.test/${e.key}',
                  },
              ],
            });
          case 'cdn.test/manifest.json':
            return json({
              'devices': [
                {
                  'segments': [
                    for (final e in footage.entries)
                      {'objectKey': e.key, 'bytes': e.value.length, 'sha256': sha256.convert(e.value).toString()},
                  ],
                },
              ],
            });
        }
        final file = footage[req.url.path.substring(1)];
        if (req.url.host == 'cdn.test' && file != null) return http.StreamedResponse(Stream.value(file), 200);
        return json({'message': 'no such thing'}, 404);
      });
}

void main() {
  late Directory dir;
  late FakeService service;
  late MemoryTokenStore store;
  late StringBuffer out;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('osb_cli');
    service = FakeService();
    store = MemoryTokenStore();
    out = StringBuffer();
  });
  tearDown(() async => dir.delete(recursive: true));

  List<Map<String, Object?>> events() =>
      [for (final l in const LineSplitter().convert(out.toString())) (jsonDecode(l) as Map).cast<String, Object?>()];

  CliHost host({Future<bool> Function(Uri)? openBrowser, Future<void>? stop, String? executable}) => CliHost(
        executable: executable ?? '${dir.path}/bin/osb',
        client: service.client,
        store: store,
        out: out,
        environment: {'OSB_WORK_FOLDER': dir.path, 'OSB_SITE': 'https://osb.test', 'HOME': dir.path},
        openBrowser: openBrowser ?? (_) async => false,
        loginPorts: const [0],
        loginTimeout: const Duration(seconds: 5),
        progressEvery: Duration.zero,
        stop: stop,
      );

  /// What the browser does: managed login sends it back to the callback.
  Future<bool> browser(Uri url, {String? state, String code = 'the-code'}) async {
    final back = Uri.parse(url.queryParameters['redirect_uri']!).replace(
      queryParameters: {'code': code, 'state': state ?? url.queryParameters['state']!},
    );
    // Not awaited: the command starts listening once the browser is open.
    unawaited(Future(() async {
      final c = HttpClient();
      final res = await (await c.getUrl(back)).close();
      await res.drain<void>();
      c.close();
    }));
    return true;
  }

  Future<void> signedIn() async {
    expect(await runCli(['sign-in'], host(openBrowser: browser)), exitOk);
    out.clear();
  }

  test('inside the app it names the engine the app carries, by its full path', () async {
    expect(await runCli(['status'], host()), exitOk);
    expect(events().single.containsKey('engine'), isFalse);
    out.clear();

    // OpenSportsBall.app/Contents/MacOS/osb and Contents/Resources/osb-engine/osb-engine
    final app = '${dir.path}/Open Sports.app/Contents';
    final engine = await File('$app/Resources/osb-engine/osb-engine').create(recursive: true);
    final inApp = host(executable: '$app/MacOS/osb');
    expect(await runCli(['status'], inApp), exitOk);
    expect(events().single, containsPair('engine', engine.path));
    expect(inApp.engineCommand, "'${engine.path}'");
  });

  test('signs in through the browser and keeps the session', () async {
    expect(await runCli(['status'], host()), exitOk);
    expect(events().single, containsPair('signedIn', false));
    out.clear();

    Uri? opened;
    final code = await runCli(['sign-in'], host(openBrowser: (u) {
      opened = u;
      return browser(u);
    }));
    expect(code, exitOk);
    expect(opened!.host, 'login.osb.test');
    expect(opened!.queryParameters['client_id'], 'desk');
    expect(opened!.queryParameters['redirect_uri'], matches(r'^http://localhost:\d+/callback$'));
    expect(opened!.queryParameters['prompt'], 'login');
    // The code is exchanged with this sign-in's verifier and the same callback.
    expect(service.tokenForm, containsPair('code', 'the-code'));
    expect(service.tokenForm!['redirect_uri'], opened!.queryParameters['redirect_uri']);
    expect(service.tokenForm!['code_verifier'], hasLength(64));
    final e = events();
    expect(e.map((x) => x['event']), ['sign_in', 'signed_in']);
    expect(e[0], containsPair('browserOpened', true));
    expect(e[1], containsPair('email', 'coach@example.com'));
    // Nothing secret is printed.
    expect(out.toString(), isNot(contains('r1')));
    expect(out.toString(), isNot(contains(service.tokenForm!['code_verifier']!)));
    expect((await Session.restore(store, service.client))!.accountId, 'acct-1');

    out.clear();
    expect(await runCli(['status'], host()), exitOk);
    expect(events().single, allOf(containsPair('signedIn', true), containsPair('site', 'https://osb.test')));
    out.clear();
    expect(await runCli(['sign-out'], host()), exitOk);
    expect(store.value, isNull);
  });

  test('a callback with the wrong state signs nobody in', () async {
    final code = await runCli(['sign-in'], host(openBrowser: (u) => browser(u, state: 'someone-elses')));
    expect(code, exitFailed);
    expect(store.value, isNull);
    expect(service.tokenForm, isNull);
    expect(events().last, containsPair('event', 'error'));
  });

  test('without a browser it prints the address and waits', () async {
    final h = host();
    final running = runCli(['sign-in', '--no-browser'], h);
    Map<String, Object?>? asked;
    for (var i = 0; i < 100 && asked == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      asked = events().where((e) => e['event'] == 'sign_in').firstOrNull;
    }
    expect(asked, containsPair('browserOpened', false));
    await browser(Uri.parse(asked!['url'] as String));
    expect(await running, exitOk);
  });

  test('a stop while waiting for the browser ends the sign-in', () async {
    final stop = Completer<void>();
    final running = runCli(['sign-in', '--no-browser'], host(stop: stop.future));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    stop.complete();
    expect(await running, exitStopped);
    expect(store.value, isNull);
  });

  test('lists games and shows one by the start of its id', () async {
    await signedIn();
    expect(await runCli(['games'], host()), exitOk);
    final games = events().single['games'] as List;
    expect(games.map((g) => (g as Map)['gameId']), [gameId, otherGame]);
    expect((games.first as Map)['status'], 'ready');
    out.clear();
    expect(await runCli(['game', '1111'], host()), exitOk);
    final g = events().single;
    expect(g['gameId'], gameId);
    final rec = (g['recordings'] as List).single as Map;
    expect(rec, allOf(containsPair('ready', true), containsPair('bytes', 90000)));
  });

  test('downloads a game where the app would put it, with a job for the engine', () async {
    await signedIn();
    expect(await runCli(['download', gameId], host()), exitOk);
    final e = events();
    final done = e.last;
    expect(done['event'], 'done');
    final folder = done['recording'] as String;
    final summary = GameSummary(gameId: gameId, createdAt: DateTime.parse('2026-10-15T16:23:00Z'));
    expect(folder, endsWith(recordingFolder('', summary, recId, onlyRecording: true)));
    expect(folder, startsWith(dir.path));
    for (final f in footage.entries) {
      expect(await File('$folder/${f.key}').readAsBytes(), f.value);
    }
    final job = jsonDecode(await File(done['job'] as String).readAsString()) as Map;
    expect(job, allOf(containsPair('schemaVersion', 1), containsPair('recording', folder)));
    expect(done['next'], "osb-engine prepare '${done['job']}'"); // the folder's name has spaces
    final progress = e.where((x) => x['event'] == 'progress').toList();
    expect(progress.last, allOf(containsPair('fraction', 1.0), containsPair('filesDone', 2)));

    // Again: nothing is fetched, and a job the app wrote is left alone.
    await File(done['job'] as String)
        .writeAsString(jsonEncode({'schemaVersion': 1, 'recording': folder, 'mine': true}));
    out.clear();
    service.asked.clear();
    expect(await runCli(['download', '1111'], host()), exitOk);
    expect(events().single, containsPair('alreadyDownloaded', true));
    expect(service.asked.where((a) => a.contains('cdn.test')), isEmpty);
    expect(jsonDecode(await File(done['job'] as String).readAsString()), containsPair('mine', true));
  });

  test('says why when there is nothing to download', () async {
    await signedIn();
    expect(await runCli(['download', otherGame], host()), exitBadInput);
    expect(events().single,
        allOf(containsPair('code', 'not_ready'), containsPair('message', contains('still uploading'))));
    out.clear();
    expect(await runCli(['download', 'ffff'], host()), exitBadInput);
    expect(events().single, containsPair('code', 'no_such_game'));
    out.clear();
    expect(await runCli(['download', gameId, '--recording', 'abcd'], host()), exitBadInput);
    expect(events().single['message'], contains('no recording abcd'));
  });

  test('a stop keeps what was downloaded and exits 130', () async {
    await signedIn();
    expect(await runCli(['download', gameId], host(stop: Future.value())), exitStopped);
    expect(events().last, containsPair('event', 'stopped'));
  });

  test('exit codes: not signed in 3, a bad command 2, the server down 4', () async {
    expect(await runCli(['games'], host()), exitSignedOut);
    expect(events().single, containsPair('code', 'signed_out'));
    for (final bad in [
      <String>[],
      ['dance'],
      ['game'],
      ['download', gameId, '--max-segments', '0'],
      ['games', '--loud'],
      ['sign-in', '--site', 'http://plain.test'],
    ]) {
      out.clear();
      expect(await runCli(bad, host()), exitBadInput, reason: '$bad');
    }
    await signedIn();
    final down = CliHost(
        client: MockClient((_) async => throw const SocketException('down')),
        store: store,
        out: out,
        environment: const {});
    expect(await runCli(['games'], down), exitFailed);
    expect(events().single, containsPair('code', 'offline'));
  });

  test('the session file is only the owner\'s to read', () async {
    final s = FileTokenStore('${dir.path}/a/b/session.json');
    expect(await s.read(), isNull);
    await s.write('{"x":1}');
    await s.write('{"x":2}');
    expect(await s.read(), '{"x":2}');
    if (!Platform.isWindows) {
      expect((await File(s.path).stat()).mode & 0x1ff, 0x180); // rw-------
    }
    await s.delete();
    await s.delete();
    expect(await s.read(), isNull);
    expect(defaultSessionFile({'OSB_SESSION_FILE': '/x/y.json'}), '/x/y.json');
  });

  test('the sign-in listener answers only its callback, on this computer', () async {
    final login = await LoopbackLogin.bind(ports: const [0]);
    addTearDown(login.close);
    expect(login.redirectUri, 'http://localhost:${login.port}/callback');
    final waiting = login.wait(timeout: const Duration(seconds: 5));
    final c = HttpClient();
    final other = await (await c.getUrl(Uri.parse('http://localhost:${login.port}/favicon.ico'))).close();
    expect(other.statusCode, 404);
    await other.drain<void>();
    final back = await (await c.getUrl(Uri.parse('${login.redirectUri}?error=access_denied&state=s'))).close();
    expect(await utf8.decodeStream(back), contains('did not finish'));
    c.close();
    expect(await waiting, '${login.redirectUri}?error=access_denied&state=s');

    final quiet = await LoopbackLogin.bind(ports: const [0]);
    addTearDown(quiet.close);
    await expectLater(quiet.wait(timeout: const Duration(milliseconds: 50)), throwsA(isA<OsbException>()));
    // A taken port moves on to the next; all taken says so.
    await expectLater(LoopbackLogin.bind(ports: [login.port]), throwsA(isA<OsbException>()));
  });
}
