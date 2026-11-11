// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Where games go on this computer, the same for the app and the `osb`
/// command, so a game downloaded by one is found by the other.
library;

import 'dart:io';

import 'api.dart';

/// Where each game's footage and results go unless people choose another
/// folder (~100 GB a game): `$OSB_WORK_FOLDER`, else Movies/OpenSportsBall.
String defaultWorkFolder([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  return env['OSB_WORK_FOLDER'] ?? '${env['HOME'] ?? '/tmp'}/Movies/OpenSportsBall';
}

/// The folder a game's recording goes in: `<work>/<date time> <game id>`.
String recordingFolder(String work, GameSummary g, String recordingId, {required bool onlyRecording}) {
  final t = g.when.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final name = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)} ${g.gameId.substring(0, 8)}';
  return onlyRecording ? '$work/$name' : '$work/$name/${recordingId.substring(0, 8)}';
}

/// The engine's launcher for a command that runs from inside the app:
/// `$OSB_ENGINE`, else the one the app carries
/// (`OpenSportsBall.app/Contents/Resources/osb-engine/osb-engine`, with
/// [executable] in `Contents/MacOS`). Null when there is neither.
String? engineLauncher([Map<String, String>? environment, String? executable]) {
  final env = environment ?? Platform.environment;
  final named = env['OSB_ENGINE'];
  if (named != null && named.isNotEmpty) return named;
  final inApp = File('${File(executable ?? Platform.resolvedExecutable).parent.parent.path}/Resources/osb-engine/osb-engine');
  return inApp.existsSync() ? inApp.path : null;
}
