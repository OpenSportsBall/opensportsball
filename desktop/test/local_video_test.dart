// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Video on this Mac: a game added from folders copied off the phones, and
/// an account's game whose second phone never uploaded, filled in from
/// such a folder or asked for with an upload-permission link.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';
import 'package:osb_desktop/src/auth.dart';
import 'package:osb_desktop/src/game_controller.dart';
import 'package:osb_desktop/src/services.dart';
import 'package:osb_desktop/src/ui/game_pane.dart';
import 'package:osb_desktop/src/ui/games_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';

const gameId = '11111111-2222-3333-4444-555555555555';
const recId = '99999999-8888-7777-6666-555555555555';
final a = Uint8List.fromList(List.generate(5000, (i) => i % 256));
final b = Uint8List.fromList(List.generate(4000, (i) => (i * 7) % 256));
String hex(List<int> x) => sha256.convert(x).toString();

Map<String, Object?> seg(String device, Uint8List data) => {
  'index': 0,
  'objectKey': '$device/${device}_000.mp4',
  'bytes': data.length,
  'sha256': hex(data),
  'startedAtDeviceMs': DateTime(2026, 11, 11, 20, 15).millisecondsSinceEpoch,
  'durationMs': 600000,
};

final mainManifest = {
  'schemaVersion': 1,
  'gameId': gameId,
  'sessionId': recId,
  'createdAt': '2026-11-12T04:15:00Z',
  'devices': [
    {
      'deviceId': 'mmm',
      'role': 'main',
      'model': 'Pixel 11',
      'platform': 'android',
      'segments': [seg('mmm', a)],
    },
    {'deviceId': 'sss', 'role': 'secondary', 'model': 'iPhone18,1', 'platform': 'ios'},
  ],
};
final report = {
  'deviceId': 'sss',
  'role': 'secondary',
  'model': 'iPhone18,1',
  'platform': 'ios',
  'segments': [seg('sss', b)],
};

/// The folders as copied off each phone.
(Directory, Directory) phoneFolders(Directory tmp) {
  final m = Directory('${tmp.path}/pixel/$gameId/$recId')..createSync(recursive: true);
  File('${m.path}/manifest.json').writeAsStringSync(jsonEncode(mainManifest));
  File('${m.path}/mmm_000.mp4').writeAsBytesSync(a);
  final s = Directory('${tmp.path}/iphone/$gameId/$recId')..createSync(recursive: true);
  File('${s.path}/report.json').writeAsStringSync(jsonEncode(report));
  File('${s.path}/recording.json').writeAsStringSync(jsonEncode({'gameId': gameId, 'recordingId': recId}));
  File('${s.path}/sss_000.mp4').writeAsBytesSync(b);
  return (m, s);
}

/// An account where the main phone uploaded and the second never did
/// ([games]: whether the account has the game at all).
Session server({bool games = true, List<String>? asked}) {
  Future<http.StreamedResponse> json(Object o, [int status = 200]) async =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(o))), status);
  final client = MockClient.streaming((req, _) async {
    final p = req.url.path;
    asked?.add('${req.method} $p');
    if (p == '/games') {
      return json({
        'games': [
          if (games)
            {'gameId': gameId, 'createdAt': '2026-11-12T04:15:00Z', 'recordingCount': 1, 'status': 'uploading'},
        ],
      });
    }
    if (p == '/games/$gameId') {
      return json({
        'gameId': gameId,
        'recordings': [
          {
            'recordingId': recId,
            'status': 'uploading',
            'devices': [
              {
                'deviceId': 'mmm',
                'role': 'main',
                'model': 'Pixel 11',
                'expectedBytes': a.length,
                'uploadedBytes': a.length,
              },
              {
                'deviceId': 'sss',
                'role': 'secondary',
                'model': 'iPhone18,1',
                'expectedBytes': null,
                'uploadedBytes': 0,
              },
            ],
          },
        ],
      });
    }
    if (p.endsWith('/downloads')) {
      return json({
        'status': 'uploading',
        'expiresAt': DateTime.now().add(const Duration(hours: 12)).toUtc().toIso8601String(),
        'manifestUrl': null,
        'manifest': mainManifest,
        'reports': <Object>[],
        'files': [
          {
            'deviceId': 'mmm',
            'fileName': 'mmm_000.mp4',
            'bytes': a.length,
            'sha256': hex(a),
            'url': 'https://cdn.test/mmm/mmm_000.mp4',
          },
        ],
      });
    }
    if (p == '/games/$gameId/grant-tickets') {
      return json({'ticket': 'osbg_${'x' * 43}', 'expiresAt': '2026-11-19T04:15:00Z'}, 201);
    }
    if (p == '/mmm/mmm_000.mp4') return http.StreamedResponse(Stream.value(a), 200);
    return http.StreamedResponse(const Stream.empty(), 404);
  });
  return Session(
    config: const SiteConfig(
      siteUrl: 'https://x.test',
      apiUrl: 'https://api.x.test',
      cognitoDomain: 'https://l.x.test',
    ),
    clientId: 'c',
    client: client,
    store: MemoryTokenStore(),
    tokens: Tokens(accessToken: 'a', expiresAt: DateTime(2100)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory work;
  late Settings settings;
  late Directory mainPhone, secondPhone;
  final summary = GameSummary(gameId: gameId, createdAt: DateTime(2026, 11, 11, 20, 15));

  setUp(() async {
    work = await Directory.systemTemp.createTemp('osb_local_video');
    settings = Settings.inMemory(File('${work.path}/settings.json'), {
      'workFolder': '${work.path}/games',
      'enginePath': File('test/fake_engine.py').absolute.path,
    });
    (mainPhone, secondPhone) = phoneFolders(work);
  });
  tearDown(() => work.delete(recursive: true));

  test('a game whose second phone never uploaded: its folder on this Mac fills it in', () async {
    final asked = <String>[];
    GameController controller() => GameController(
      summary: summary,
      session: server(asked: asked),
      settings: settings,
      onSignedOut: () {},
    );
    final ctl = controller();
    await ctl.open();
    expect(ctl.phase, Phase.needsDownload);
    expect(ctl.needsFootage, isTrue);
    expect(ctl.error, isNull);

    // The main phone's folder alone doesn't help: which phone is still missing.
    final missing = await ctl.addFromDisk([mainPhone.path]);
    expect(missing!.role, 'secondary');
    expect(missing.model, 'iPhone18,1');
    expect(ctl.phase, Phase.needsDownload);

    // The second phone's: its video is copied, the main phone's downloaded, and it gets ready.
    expect(await ctl.addFromDisk([secondPhone.path]), isNull);
    expect(ctl.error, isNull);
    expect(ctl.phase, Phase.questions);
    expect(File('${ctl.folder!.path}/sss/sss_000.mp4').readAsBytesSync(), b);
    expect(File('${ctl.folder!.path}/mmm/mmm_000.mp4').readAsBytesSync(), a);
    expect(asked, contains('GET /mmm/mmm_000.mp4'));
    expect(File('${secondPhone.path}/sss_000.mp4').existsSync(), isTrue); // the folder chosen is left alone
    expect(ctl.needsFootage, isFalse);
    expect(settings.knownGame(recId)!.sources, [secondPhone.path]);

    // A new launch: the account still says uploading, the game is where it was.
    final again = controller();
    await again.open();
    expect(again.phase, Phase.questions);
    expect(again.needsFootage, isFalse);
    expect(again.awaitingUpload, isFalse);
  });

  test('a game added from the two phones\' folders is processed, shares nothing, and can be removed', () async {
    final asked = <String>[];
    final local = LocalGame(
      gameId: gameId,
      recordingId: recId,
      when: DateTime(2026, 11, 11, 20, 15),
      folder: '${work.path}/games/local one',
      sources: [mainPhone.path, secondPhone.path],
    );
    await settings.saveLocalGame(local);
    await settings.setSharingAgreed(true);
    var removed = false;
    GameController controller() => GameController(
      summary: local.summary,
      session: server(asked: asked),
      settings: settings,
      onSignedOut: () {},
      local: settings.localGames.single,
      onRemoved: () => removed = true,
    );
    final ctl = controller();
    await ctl.open();
    expect(ctl.phase, Phase.needsDownload);
    expect(ctl.recording!.devices.map((d) => d.model), ['Pixel 11', 'iPhone18,1']);
    expect(ctl.recording!.expectedBytes, a.length + b.length);

    await ctl.startDownload(); // from the folders it was added from
    expect(ctl.error, isNull);
    expect(ctl.phase, Phase.questions);
    await ctl.answer((x) => x.approvePitch(ctl.questions!.pitch!.round, share: true));
    await ctl.run();
    expect(ctl.phase, Phase.done);
    await ctl.sendAgreed();
    expect(asked, isEmpty); // nothing asked of the account, nothing sent

    final again = controller();
    await again.open();
    expect(again.phase, Phase.done);

    expect(again.canDeleteLocal, isTrue);
    await again.deleteLocal();
    expect(removed, isTrue);
    expect(Directory(local.folder).existsSync(), isFalse);
    expect(settings.localGames, isEmpty);
    expect(File('${mainPhone.path}/mmm_000.mp4').existsSync(), isTrue);
  });

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// Lets real file and process work finish, and what waits on it carry on.
  Future<void> settle(WidgetTester tester, [int rounds = 10]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the game says which phone\'s video is missing, and gives a link to ask for it', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ctl = GameController(summary: summary, session: server(), settings: settings, onSignedOut: () {});
    await tester.runAsync(ctl.open);
    await tester.pumpWidget(app(GamePane(controller: ctl)));
    expect(find.text('Not all of this game’s video is in your account.'), findsOneWidget);
    expect(find.textContaining('Pixel 11: '), findsOneWidget);
    expect(find.text('nothing in your account yet'), findsOneWidget);
    expect(find.text('Select video on this Mac…'), findsOneWidget);
    expect(find.textContaining('Download the footage'), findsNothing);

    await tester.tap(find.text('Request footage from another phone'));
    await settle(tester, 4);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('https://x.test/grant#osbg_${'x' * 43}'), findsOneWidget);
    expect(find.textContaining('Works until Nov 1'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
  });

  testWidgets('"+" adds a game from folders on this Mac, asking for the second phone\'s too', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picked = [
      [mainPhone.path],
      [secondPhone.path],
    ];
    final was = pickFolders;
    pickFolders = () async => picked.removeAt(0);
    addTearDown(() => pickFolders = was);
    final session = server(games: false);
    final key = GlobalKey<GamesScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        home: GamesScreen(
          key: key,
          session: session,
          auth: AuthController(client: session.client, store: MemoryTokenStore(), session: session),
          settings: settings,
          client: session.client,
        ),
      ),
    );
    await settle(tester);
    expect(find.textContaining('No games yet'), findsOneWidget);
    await tester.tap(find.byTooltip('Add a game from video on this Mac'));
    await settle(tester);
    expect(find.text('The second phone’s video is needed too'), findsOneWidget);
    expect(find.textContaining('(the iPhone18,1)'), findsOneWidget);
    await tester.tap(find.text('Choose its folder…'));
    // Copies, then the stand-in engine gets it ready.
    for (var i = 0; i < 100 && find.text('Needs your check').evaluate().isEmpty; i++) {
      await settle(tester, 2);
    }

    expect(settings.localGames.single.sources, [mainPhone.path, secondPhone.path]);
    expect(find.text('On this Mac'), findsNothing); // it is at its check by now
    expect(find.text('Needs your check'), findsOneWidget);
    expect(find.textContaining('Share this pitch map'), findsNothing); // not in the account to share from
    expect(File('${settings.localGames.single.folder}/manifest.json').existsSync(), isTrue);
    await tester.runAsync(() => key.currentState!.shutdown());
  });
}
