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

void main() {
  testWidgets('"Show in Finder" only once the game has a folder', (tester) async {
    final dir = Directory.systemTemp.createTempSync('osb_pane');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ctl =
        GameController(
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
          )
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
