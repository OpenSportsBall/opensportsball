// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:osb_core/osb_core.dart';

/// The `osb` command (lib/src/cli.dart). Build one file to hand out with
/// `dart compile exe bin/osb.dart -o osb`.
Future<void> main(List<String> args) async {
  final stop = Completer<void>();
  final signals = [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm]
      .map((s) => s.watch().listen((_) {
            // Once: stop tidily (a download keeps its partial files). Twice: just go.
            if (stop.isCompleted) exit(exitStopped);
            stop.complete();
          }))
      .toList();
  final code = await runCli(args, CliHost(stop: stop.future));
  for (final s in signals) {
    await s.cancel();
  }
  await stdout.flush();
  exit(code);
}
