// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Making a game's video again: which of the engine's results to throw
/// away so its next `run` makes them anew.
///
/// The engine skips every step whose output is on disk (its `run` carries
/// on where it was), and has no command to redo one. So the app deletes
/// the outputs of the stages the user picked, and runs it as usual. The
/// checks before the run (the pitch, the cameras, the kits) are kept.
library;

import 'dart:io';

/// A stage of `run` that can be made again.
enum RegenPart {
  /// Where the ball is, in every frame (`detect/ball_*`).
  ball,

  /// Who is on the pitch: players by team, keepers, the referee (`detect/roles_*`).
  players,

  /// Where the camera looks, and the video rendered from it (`fullgame/`).
  video,

  /// The 1440p copy of the video for YouTube.
  youtube,
}

/// [picked] and what has to be made again with it: the video is made from
/// the ball and the players, and the YouTube copy from the video.
Set<RegenPart> regenWith(Set<RegenPart> picked, {required bool youtubeCopy}) {
  final parts = {...picked};
  if (parts.contains(RegenPart.ball) || parts.contains(RegenPart.players)) parts.add(RegenPart.video);
  if (parts.contains(RegenPart.video) && youtubeCopy) parts.add(RegenPart.youtube);
  if (!youtubeCopy && !parts.contains(RegenPart.video)) parts.remove(RegenPart.youtube);
  return parts;
}

/// The game in [folder] has results of an earlier run to make again.
bool hasRunResults(Directory folder) {
  for (final d in ['detect', 'fullgame/pieces']) {
    final dir = Directory('${folder.path}/$d');
    try {
      if (dir.existsSync() && dir.listSync(followLinks: false).isNotEmpty) return true;
    } on FileSystemException {
      // being deleted
    }
  }
  return File('${folder.path}/fullgame/game.mp4').existsSync();
}

/// Deletes from the game's [folder] what the engine made in [parts]
/// (already widened by [regenWith]), so that its next run makes them again.
Future<void> clearForRegen(Directory folder, Set<RegenPart> parts) async {
  Future<void> remove(String path) async {
    final type = await FileSystemEntity.type('${folder.path}/$path', followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    await (type == FileSystemEntityType.directory ? Directory('${folder.path}/$path') : File('${folder.path}/$path'))
        .delete(recursive: true);
  }

  Future<void> removeNamed(String dir, bool Function(String name) test) async {
    final d = Directory('${folder.path}/$dir');
    if (!await d.exists()) return;
    await for (final e in d.list(followLinks: false)) {
      if (test(e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))) await e.delete(recursive: true);
    }
  }

  if (parts.contains(RegenPart.ball)) {
    await removeNamed('detect', (n) => n.startsWith('ball_'));
  }
  if (parts.contains(RegenPart.players)) {
    await removeNamed('detect', (n) => n.startsWith('roles_'));
  }
  if (parts.contains(RegenPart.video)) {
    // The finished mark first: without it the engine takes the game as not made.
    for (final f in ['done.json', 'game.mp4', 'video.mp4', 'audio.m4a', 'pieces.txt', 'pieces']) {
      await remove('fullgame/$f');
    }
    // What the last run said of each segment and of the ball: about the video that is gone.
    await removeNamed('fullgame/logs', (n) => n.startsWith('follow_'));
    await remove('engine/events.jsonl');
  }
  if (parts.contains(RegenPart.youtube)) {
    await remove('fullgame/game-youtube.mp4');
  }
}
