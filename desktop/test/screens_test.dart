// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Renders the game pane's screens to PNGs, with the brand fonts and a
/// prepared recording's real pictures (its questions.json, panorama and
/// kit crops), to look at without clicking through the app:
///
///     OSB_SCREENS_RECORDING=/path/to/prepared/rec OSB_SCREENS_OUT=/tmp/screens \
///     flutter test test/screens_test.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:osb_core/osb_core.dart';
import 'package:osb_desktop/src/brand.dart';
import 'package:osb_desktop/src/game_controller.dart';
import 'package:osb_desktop/src/services.dart';
import 'package:osb_desktop/src/ui/game_pane.dart';

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final l = FontLoader(name);
    for (final f in files) {
      l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await l.load();
  }

  await family('Rubik', [
    'assets/fonts/Rubik-Medium.ttf',
    'assets/fonts/Rubik-SemiBold.ttf',
    'assets/fonts/Rubik-Bold.ttf',
  ]);
  await family('Atkinson Hyperlegible', [
    'assets/fonts/AtkinsonHyperlegible-Regular.ttf',
    'assets/fonts/AtkinsonHyperlegible-Bold.ttf',
  ]);
  await family('IBM Plex Mono', ['assets/fonts/IBMPlexMono-Regular.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/opt/homebrew/share/flutter';
  await family('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
}

void main() {
  final rec = Platform.environment['OSB_SCREENS_RECORDING'];
  final out = Platform.environment['OSB_SCREENS_OUT'];
  final skip = rec == null || out == null ? 'needs OSB_SCREENS_RECORDING and OSB_SCREENS_OUT' : null;

  late GameController ctl;
  late Map<String, Object?> raw;

  setUp(() async {
    if (skip != null) return;
    await _loadFonts();
    raw = (jsonDecode(File('$rec/engine/questions.json').readAsStringSync()) as Map).cast();
    final session = Session(
      config: const SiteConfig(
        siteUrl: 'https://x.test',
        apiUrl: 'https://api.x.test',
        cognitoDomain: 'https://l.x.test',
      ),
      clientId: 'c',
      client: MockClient((_) async => http.Response('{}', 404)),
      store: MemoryTokenStore(),
      tokens: Tokens(accessToken: 'a', expiresAt: DateTime(2100)),
    );
    final summary = GameSummary(
      gameId: 'f68af87f-60ac-4b13-ab1c-893053910ac5',
      createdAt: DateTime(2026, 10, 15, 9, 23),
      recordedAt: DateTime(2026, 10, 15, 9, 23),
    );
    ctl =
        GameController(
            summary: summary,
            session: session,
            settings: Settings.inMemory(File('${Directory.systemTemp.path}/osb-screens-settings.json')),
            onSignedOut: () {},
          )
          ..folder = Directory(rec!)
          ..recording = const Recording(
            recordingId: 'r',
            status: 'ready',
            devices: [
              RecordingDevice(deviceId: 'a', role: 'main', model: 'Google Pixel 11', expectedBytes: 10010902500),
              RecordingDevice(
                deviceId: 'b',
                role: 'secondary',
                model: 'Google Pixel 11 Pro',
                expectedBytes: 10010743419,
              ),
            ],
          )
          ..checks = const [
            Check(true, 'Apple Silicon', 'This Mac has an Apple chip.'),
            Check(true, 'Memory', '36 GB'),
            Check(true, 'Disk space', '135 GB free; this game needs about 50 GB.'),
            Check(false, 'Power', 'On battery: plug in. Processing pauses on battery.'),
          ];
  });

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    Future<void> Function()? before,
    List<String> images = const [],
  }) async {
    tester.view.physicalSize = const Size(1020, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    // Pictures load first, for real: a load started under the test's fake
    // clock would never finish.
    await tester.pumpWidget(MaterialApp(home: SizedBox(key: key)));
    await tester.runAsync(() async {
      for (final i in images) {
        await precacheImage(FileImage(File('$rec/$i')), key.currentContext!);
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildBrandTheme(Brightness.light),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(body: GamePane(controller: ctl)),
        ),
      ),
    );
    if (before != null) await before();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(out!).create(recursive: true);
      await File('$out/$name.png').writeAsBytes(png!.buffer.asUint8List());
    });
  }

  testWidgets('download', (tester) async {
    ctl.phase = Phase.needsDownload;
    await shoot(tester, '1-download');
    ctl
      ..phase = Phase.downloading
      ..download = const DownloadProgress(
        doneBytes: 7400000000,
        totalBytes: 20021645919,
        filesDone: 5,
        files: 16,
        bytesPerSecond: 56e6,
      )
      ..fraction = 0.37
      ..etaS = 225;
    await shoot(tester, '2-downloading');
  }, skip: skip != null);

  testWidgets('pitch check', (tester) async {
    final p = (raw['pitch'] as Map).cast<String, Object?>()..['status'] = 'pending';
    ctl
      ..phase = Phase.questions
      ..questions = EngineQuestions(pending: const ['pitch', 'kits'], pitch: PitchQuestion.fromJson(p));
    final images = [p['background'] as String];
    await shoot(tester, '3-pitch', images: images);
    await shoot(
      tester,
      '4-pitch-mark',
      images: images,
      before: () async {
        await tester.tap(find.text('No, mark the pitch'));
        await tester.pump();
        await tester.pump();
        // Click a little beside the first point, which the view is zoomed to.
        final view = tester.getRect(find.byType(InteractiveViewer));
        await tester.tapAt(view.center + const Offset(30, 12));
        await tester.pump();
      },
    );
  }, skip: skip != null);

  testWidgets('kit check', (tester) async {
    final k = (raw['kits'] as Map).cast<String, Object?>()..['status'] = 'pending';
    final q = KitsQuestion.fromJson(k);
    ctl
      ..phase = Phase.questions
      ..questions = EngineQuestions(pending: const ['kits'], kits: q);
    await shoot(
      tester,
      '5-kits',
      images: [
        for (final g in q.groups.take(3))
          for (final c in g.crops) c.image,
      ],
      before: () async {
        await tester.tap(find.byType(Image).at(2));
        await tester.pump();
      },
    );
  }, skip: skip != null);

  testWidgets('run and done', (tester) async {
    ctl
      ..questions = null
      ..phase = Phase.readyToRun;
    await shoot(tester, '6-ready');
    ctl
      ..phase = Phase.running
      ..activity = 'Processing the game'
      ..fraction = 0.42
      ..etaS = 3.4 * 3600;
    await shoot(tester, '7-running');
    ctl
      ..phase = Phase.done
      ..output = '$rec/fullgame/game.mp4';
    await shoot(tester, '8-done');
  }, skip: skip != null);
}
