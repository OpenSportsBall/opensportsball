// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';
import 'package:osb_desktop/src/game_controller.dart';
import 'package:osb_desktop/src/services.dart';
import 'package:osb_desktop/src/ui/ball_views.dart';
import 'package:osb_desktop/src/ui/game_pane.dart';

GameController _controller(Directory dir) => GameController(
  summary: GameSummary(gameId: '11111111-2222-3333-4444-555555555555', createdAt: DateTime(2026, 10, 15)),
  session: Session(
    config: const SiteConfig(
      siteUrl: 'https://x.test',
      apiUrl: 'https://api.x.test',
      cognitoDomain: 'https://l.x.test',
    ),
    clientId: 'c',
    client: MockClient((_) async => http.Response('{}', 404)),
    store: MemoryTokenStore(),
    tokens: Tokens(accessToken: 'a', expiresAt: DateTime(2100)),
  ),
  settings: Settings.inMemory(File('${dir.path}/settings.json')),
  onSignedOut: () {},
);

void main() {
  test('before the engine can estimate, the app does, from the chunk count; then the engine\'s', () {
    final dir = Directory.systemTemp.createTempSync('osb_eta');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ctl = _controller(dir)
      ..phase = Phase.running
      ..chunks = 10
      ..runElapsedS = 30 * 60;
    expect(ctl.etaIsEstimate, isTrue);
    expect(ctl.shownEtaS, 10 * usualChunkSeconds - 30 * 60);
    expect(ctl.shownFraction, closeTo(1800 / (10 * usualChunkSeconds), 1e-9));
    expect(runDetail(ctl), startsWith('30 min so far · about 8 h '));
    expect(runDetail(ctl), endsWith('an estimate until the first 10 minutes of video are done'));
    expect(runDetail(ctl), isNot(contains('0%')));

    // A slow Mac: the bar stops short of the end, the estimate at a minute.
    ctl.runElapsedS = 20 * 3600;
    expect(ctl.shownFraction, 0.95);
    expect(ctl.shownEtaS, 60);

    // Once the engine has one chunk done, its own figures.
    ctl
      ..fraction = 0.1
      ..etaS = 3.4 * 3600
      ..runElapsedS = 52 * 60;
    expect(ctl.etaIsEstimate, isFalse);
    expect(ctl.shownFraction, 0.1);
    expect(runDetail(ctl), '10% · 52 min so far · about 3 h 24 min left');
  });

  testWidgets('"Show in Finder" only once the game has a folder', (tester) async {
    final dir = Directory.systemTemp.createTempSync('osb_pane');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ctl = _controller(dir)
      ..phase = Phase.needsDownload
      ..folder = Directory('${dir.path}/game');

    Future<void> show() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GamePane(controller: ctl)),
      ),
    );
    await show();
    expect(find.text('Show in Finder'), findsNothing);

    ctl.folder!.createSync();
    await show();
    expect(find.text('Show in Finder'), findsOneWidget);

    // Working on a step: how long so far, how long it usually takes, its log.
    ctl
      ..phase = Phase.preparing
      ..activity = stepName('kit-sample')
      ..step = 'kit-sample'
      ..stepStartedAt = DateTime.now().subtract(const Duration(minutes: 9, seconds: 5))
      ..stepLog = '${ctl.folder!.path}/engine/logs/kit-sample.log';
    await show();
    expect(find.text('Finding people on the pitch'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^9 min 0\d s so far · usually about 8 min$')), findsOneWidget);
    expect(find.text('Show the log'), findsOneWidget);
    ctl.stepStartedAt = DateTime.now().subtract(const Duration(minutes: 20));
    await show();
    expect(find.textContaining('slower than usual, still working'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the clock's timer
  });

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('a ball the engine doesn\'t know is said from the second segment, with the segments to look at', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('osb_ball');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ctl = _controller(dir)
      ..phase = Phase.running
      ..folder = Directory('${dir.path}/game')
      ..chunks = 10
      ..ball = const BallCheck(aimShare: 0.31, byChunk: [31]);
    await tester.pumpWidget(app(GamePane(controller: ctl)));
    expect(find.textContaining('doesn’t know this ball'), findsNothing); // one segment can't tell

    ctl
      ..ball = const BallCheck(aimShare: 0.165, byChunk: [31, 2], low: true)
      ..chunkDetails = [
        const ChunkDetail(
          chunk: 0,
          startS: 0,
          seconds: 600,
          ball: ChunkStage(status: 'done', seconds: 3000, log: '/x/ball_00.log'),
          follow: ChunkStage(status: 'done', seconds: 2700),
          ballAimPct: 31,
          ballDetectedPct: 12,
        ),
        const ChunkDetail(
          chunk: 1,
          startS: 600,
          seconds: 600,
          ball: ChunkStage(status: 'done', seconds: 3100),
          follow: ChunkStage(status: 'done', seconds: 2500),
          ballAimPct: 2,
        ),
        ChunkDetail(
          chunk: 2,
          startS: 1200,
          seconds: 600,
          ball: ChunkStage(status: 'running', startedAt: DateTime.now().subtract(const Duration(minutes: 12))),
          follow: const ChunkStage(status: 'waiting'),
        ),
      ];
    await tester.pumpWidget(app(GamePane(controller: ctl)));
    expect(find.text('The engine doesn’t know this ball yet'), findsOneWidget);
    expect(find.textContaining('17% of the 2 segments done so far (31%, 2%)'), findsOneWidget);
    expect(find.textContaining('Processing carries on as usual'), findsOneWidget);
    expect(find.text('Mark the ball'), findsOneWidget);

    await tester.tap(find.text('Segments'));
    await tester.pump();
    expect(find.text('0:00 – 10:00'), findsOneWidget);
    expect(find.text('20:00 – 30:00'), findsOneWidget);
    expect(find.text('Done in 50 min'), findsOneWidget);
    expect(find.text('Working, 12 min so far'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('31%'), findsOneWidget);
    expect(find.text('2%'), findsOneWidget);
    expect(find.byTooltip('Show the log'), findsOneWidget);
    // Not processing any more: the stage it was in was stopped there.
    ctl.phase = Phase.readyToRun;
    ctl.notifyListeners();
    await tester.pump();
    expect(find.text('Stopped part-way'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpWidget(const SizedBox()); // stops the dialog's timer
  });

  testWidgets('marking the ball: locked until sharing is agreed, then a click per picture', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('osb_label');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ctl = _controller(dir)
      ..phase = Phase.done
      ..folder = Directory('${dir.path}/game');
    // A set the engine made earlier (unfinished sets are carried on with).
    final sd = Directory('${ctl.folder!.path}/engine/labels/ball-1')..createSync(recursive: true);
    File('${sd.path}/set.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'set': 'ball-1',
        'kind': 'ball',
        'labelled': 0,
        'items': [
          for (var i = 0; i < 2; i++)
            {
              'id': 'b$i',
              'image': 'images/b$i.jpg',
              'videoT': 125.0 + 600 * i,
              'width': 3840,
              'height': 2160,
              'suggestions': [
                {'x': 1920.0, 'y': 1080.0, 'conf': 0.7},
              ],
            },
        ],
      }),
    );

    await tester.pumpWidget(app(BallLabelScreen(controller: ctl)));
    expect(find.text('Marking the ball is for sharing'), findsOneWidget);
    expect(find.textContaining('nothing is sent yet'), findsOneWidget);
    expect(find.textContaining('Picture 1 of 2'), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(find.text('I agree to share them'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(ctl.settings.shareLabels, isTrue);
    expect(find.text('Picture 1 of 2'), findsOneWidget);
    expect(find.text('2:05 into the game'), findsOneWidget);
    expect(find.text('0 of 2 marked'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next')).onPressed, isNull);

    // Whole picture, then a click just beside the engine's ring takes the ring.
    await tester.tap(find.text('Whole picture'));
    await tester.pump();
    final box = tester.getRect(find.byType(InteractiveViewer));
    await tester.tapAt(box.center + const Offset(3, -2));
    await tester.pump();
    expect(find.text('Ball marked'), findsOneWidget);
    expect(find.text('1 of 2 marked'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text('Picture 2 of 2'), findsOneWidget);
    await tester.tap(find.text('The ball isn’t in the picture'));
    await tester.pump();
    expect(find.text('2 of 2 marked'), findsOneWidget);
    expect(find.text('Save and close'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Finish')).onPressed, isNotNull);
  });
}
