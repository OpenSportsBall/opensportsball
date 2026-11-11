// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// A game from the games list to game.mp4, with a stand-in API and footage
/// server and a stand-in engine (fake_engine.py: the real commands, files
/// and progress lines).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';
import 'package:osb_desktop/src/game_controller.dart';
import 'package:osb_desktop/src/services.dart';

const gameId = '11111111-2222-3333-4444-555555555555';
const recId = '99999999-8888-7777-6666-555555555555';
final seg = Uint8List.fromList(List.generate(5000, (i) => i % 256));

Session fakeServer({String status = 'ready'}) {
  final sha = sha256.convert(seg).toString();
  final manifest = {
    'gameId': gameId,
    'devices': [
      {
        'deviceId': 'main',
        'role': 'main',
        'segments': [
          {'index': 0, 'objectKey': 'main/main_000.mp4', 'bytes': seg.length, 'sha256': sha},
        ],
      },
    ],
  };
  Future<http.StreamedResponse> json(Object o) async =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(o))), 200);
  final client = MockClient.streaming((req, _) async {
    final p = req.url.path;
    if (p == '/games/$gameId') {
      return json({
        'gameId': gameId,
        'recordings': [
          {
            'recordingId': recId,
            'status': status,
            'devices': [
              {'deviceId': 'main', 'role': 'main', 'model': 'Pixel', 'expectedBytes': seg.length},
            ],
          },
        ],
      });
    }
    if (p.endsWith('/downloads')) {
      return json({
        'status': status,
        'expiresAt': DateTime.now().add(const Duration(hours: 12)).toUtc().toIso8601String(),
        'manifestUrl': 'https://cdn.test/manifest.json',
        'files': [
          {
            'deviceId': 'main',
            'fileName': 'main_000.mp4',
            'bytes': seg.length,
            'sha256': sha,
            'url': 'https://cdn.test/main/main_000.mp4',
          },
        ],
      });
    }
    if (p == '/manifest.json') return json(manifest);
    if (p == '/main/main_000.mp4') return http.StreamedResponse(Stream.value(seg), 200);
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
  final summary = GameSummary(
    gameId: gameId,
    createdAt: DateTime(2026, 10, 15, 9, 23),
    recordedAt: DateTime(2026, 10, 15, 9, 23),
  );

  setUp(() async {
    work = await Directory.systemTemp.createTemp('osb_flow');
    settings = Settings.inMemory(File('${work.path}/settings.json'), {
      'workFolder': '${work.path}/games',
      'enginePath': File('test/fake_engine.py').absolute.path,
    });
  });
  tearDown(() => work.delete(recursive: true));

  GameController controller(Session s) =>
      GameController(summary: summary, session: s, settings: settings, onSignedOut: () {});

  test('download, prepare, the checks, the run, and picking up where it was after a restart', () async {
    final ctl = controller(fakeServer());
    await ctl.open();
    expect(ctl.phase, Phase.needsDownload);
    expect(ctl.folder!.path, endsWith('/games/2026-10-15 09.23 11111111'));

    await ctl.startDownload(); // prepares by itself
    expect(ctl.error, isNull);
    expect(File('${ctl.folder!.path}/main/main_000.mp4').readAsBytesSync(), seg);
    expect(ctl.phase, Phase.questions);
    expect(ctl.questions!.pending, ['pitch', 'kits']);
    // The last step's name, start and log, for the step clock.
    expect(ctl.step, 'pitch');
    expect(ctl.stepStartedAt, isNotNull);
    expect(ctl.stepLog, '${ctl.folder!.path}/engine/logs/pitch.log');

    await ctl.answer((a) => a.approvePitch(ctl.questions!.pitch!.round, share: true));
    expect(ctl.questions!.pending, ['kits']);
    await ctl.answer(
      (a) => a.answerKits(
        ctl.questions!.kits!.round,
        tapped: {
          0: {'c0_00'},
        },
        share: false,
      ),
    );
    expect(ctl.phase, Phase.readyToRun);

    // The engine got the job and every answer.
    final calls = [
      for (final l in File('${ctl.folder!.path}/engine/calls.jsonl').readAsLinesSync()) jsonDecode(l) as Map,
    ];
    final last = calls.lastWhere((c) => c['cmd'] == 'prepare');
    expect(last['answers'], {
      'pitch': {'round': 1, 'approve': true, 'share': true},
      'kits': {
        'round': 1,
        'tapped': {
          '0': ['c0_00'],
        },
        'share': false,
      },
    });
    expect((last['job'] as Map)['recording'], ctl.folder!.path);

    final fractions = <double>[];
    int? lowAfter;
    ctl.addListener(() {
      if (ctl.fraction != null) fractions.add(ctl.fraction!);
      if (ctl.ballLow) lowAfter ??= ctl.ball!.byChunk.length;
    });
    await ctl.run();
    expect(ctl.phase, Phase.done);
    expect(ctl.output, endsWith('fullgame/game.mp4'));
    expect(fractions, containsAllInOrder([0.25, 0.5, 0.75]));
    expect(File('${ctl.folder!.path}/engine/app-run.pid').existsSync(), isFalse);

    // From its second chunk the engine said it doesn't know this ball.
    expect(lowAfter, 2);
    expect(ctl.ballLow, isTrue);
    expect(ctl.ball!.byChunk, [31, 2, 0, 1]);

    // A new launch finds it done, from the folder alone: the ball and each segment too.
    final again = controller(fakeServer());
    await again.open();
    expect(again.phase, Phase.done);
    expect(again.ballLow, isTrue);
    expect(again.chunkDetails, hasLength(4));
    expect(again.chunkDetails[1].ballAimPct, 2);
    expect(again.chunkDetails[1].follow.status, 'done');
    expect(again.chunkDetails[1].startS, 600);

    // Ball labels: the engine picks the frames, the labels go back to it, and a
    // set begun is carried on with, not made again.
    final set = await again.ballSet();
    expect(set.frames.map((f) => f.id), ['b0', 'b1', 'b2']);
    expect(File(set.frames.first.image).existsSync(), isTrue);
    expect(set.frames.first.suggestions.single.x, 1000);
    var now = await again.saveBallLabels(set, {'b0': const BallAt(1000, 500), 'b2': const NoBall()});
    expect(now.labelled, 2);
    expect(now.complete, isFalse);
    expect((await again.ballSet()).name, 'ball-1');
    expect((await again.ballSet()).labels['b0'], isA<BallAt>());
    now = await again.saveBallLabels(now, {'b1': const BallUnsure()});
    expect(now.complete, isTrue);
    final stored = jsonDecode(File('${now.folder.path}/answers.json').readAsStringSync()) as Map;
    expect(stored, {
      'b0': {'status': 'ball', 'x': 1000.0, 'y': 500.0},
      'b2': {'status': 'none'},
      'b1': {'status': 'unsure'},
    });
    expect(File('${again.folder!.path}/engine/share/ball-1.json').existsSync(), isTrue);
  });

  test('a recording still uploading is not downloaded', () async {
    final ctl = controller(fakeServer(status: 'uploading'));
    await ctl.open();
    expect(ctl.phase, Phase.needsDownload);
    expect(ctl.error, contains('still uploading'));
  });

  test('without an engine it says where to set one', () async {
    await settings.set('enginePath', '/nonexistent/osb-engine');
    final ctl = controller(fakeServer());
    await ctl.open();
    await ctl.startDownload();
    expect(ctl.error, contains('No processing engine'));
  });

  test('the games folder is named by date and game, and by recording when there are several', () {
    expect(recordingFolder('/w', summary, recId, onlyRecording: true), '/w/2026-10-15 09.23 11111111');
    expect(recordingFolder('/w', summary, recId, onlyRecording: false), '/w/2026-10-15 09.23 11111111/99999999');
  });
}
