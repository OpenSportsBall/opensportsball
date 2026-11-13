// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// The whole way through with the real engine, on a recording already on
/// this Mac, served by the demo stand-in (src/demo.dart). Slow (minutes to
/// an hour) and needs footage, so it runs only when asked:
///
///     OSB_DEMO_RECORDING=/path/to/rec OSB_ENGINE=/path/to/osb-engine/osb-engine \
///     OSB_WORK_FOLDER=/tmp/osb-e2e [OSB_E2E_RUN=1 OSB_MAX_CHUNKS=1] \
///     flutter test test/e2e_test.dart
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osb_core/osb_core.dart';
import 'package:osb_desktop/src/demo.dart';
import 'package:osb_desktop/src/game_controller.dart';
import 'package:osb_desktop/src/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final skip = env['OSB_DEMO_RECORDING'] == null || env['OSB_ENGINE'] == null || env['OSB_WORK_FOLDER'] == null
      ? 'needs OSB_DEMO_RECORDING, OSB_ENGINE and OSB_WORK_FOLDER'
      : null;

  test(
    'download, prepare, the checks, and (with OSB_E2E_RUN) the run',
    () async {
      final session = demoSession()!;
      final dir = await Directory.systemTemp.createTemp('osb_e2e_settings');
      final settings = Settings.inMemory(File('${dir.path}/settings.json'));
      final games = await session.games();
      final ctl = GameController(
        summary: games.single,
        session: session,
        settings: settings,
        onSignedOut: () => fail('signed out'),
      );
      final log = <String>[];
      ctl.addListener(() {
        final line = '${ctl.phase.name} ${ctl.activity ?? ''} ${ctl.fraction?.toStringAsFixed(2) ?? ''}';
        if (log.isEmpty || log.last != line) {
          log.add(line);
          // ignore: avoid_print
          print('${DateTime.now().toIso8601String().substring(11, 19)} $line');
        }
      });

      await ctl.open();
      expect(ctl.error, isNull);
      if (ctl.phase == Phase.needsDownload) {
        await ctl.startDownload(); // then prepares by itself
      } else if (ctl.phase == Phase.needsPrepare) {
        await ctl.prepare();
      }
      expect(ctl.error, isNull, reason: ctl.errorLog);
      expect(await FootageDownloader.isComplete(ctl.folder!), isTrue);
      expect(ctl.phase, anyOf(Phase.questions, Phase.readyToRun));

      final q = ctl.questions!;
      if (q.cameras?.pending ?? false) {
        await ctl.answer((a) => a.answerCameras(q.cameras!.round, mainLeft: false));
      }
      final pitch = ctl.questions!.pitch!;
      if (pitch.pending) {
        expect(pitch.points, isNotEmpty);
        expect(File('${ctl.folder!.path}/${pitch.background}').existsSync(), isTrue);
        await ctl.answer((a) => a.approvePitch(pitch.round, share: true));
      }
      expect(ctl.error, isNull, reason: ctl.errorLog);
      expect(ctl.phase, Phase.readyToRun);

      if (env['OSB_E2E_RUN'] == '1') {
        await ctl.run();
        expect(ctl.error, isNull, reason: ctl.errorLog);
        expect(ctl.phase, Phase.done);
        expect(File(ctl.output!).existsSync(), isTrue);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(hours: 3)),
  );
}
