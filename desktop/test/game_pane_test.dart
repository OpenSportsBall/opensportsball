// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';
import 'package:osb_desktop/src/game_controller.dart';
import 'package:osb_desktop/src/services.dart';
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
}
