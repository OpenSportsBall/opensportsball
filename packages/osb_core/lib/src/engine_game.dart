// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// What the engine says about a game while and after it processes it: how
/// the ball is going, each chunk's two stages, and the ball label sets
/// (shared/schemas/engine-event, engine-labelset and
/// engine-label-answers.schema.json).
library;

import 'dart:convert';
import 'dart:io';

import 'engine.dart';

/// How much of the game so far the camera aimed at the ball: the `ball`
/// event after each chunk, and the same fields of `done` and `status`.
class BallCheck {
  const BallCheck({required this.aimShare, required this.byChunk, this.low});

  /// 0 to 1, over the chunks followed so far.
  final double aimShare;

  /// Percent per chunk.
  final List<int> byChunk;

  /// True when the models don't know this ball. Null while one chunk of a
  /// running game is all there is: the first can look fine and the rest not.
  final bool? low;

  /// From an event's fields, or null when it has none of them.
  static BallCheck? of(Map<String, Object?> j) {
    final share = j['ballAimShare'];
    if (share is! num) return null;
    return BallCheck(
      aimShare: share.toDouble(),
      byChunk: [for (final v in (j['ballAimByChunk'] as List? ?? [])) (v as num).toInt()],
      low: j['ballLow'] as bool?,
    );
  }
}

/// One of a chunk's two stages.
class ChunkStage {
  const ChunkStage({required this.status, this.seconds, this.startedAt, this.log});

  /// `waiting`, `running`, `done` or `failed`.
  final String status;
  final double? seconds;
  final DateTime? startedAt;
  final String? log;

  factory ChunkStage.fromJson(Map<String, Object?> j) => ChunkStage(
        status: j['status'] as String? ?? 'waiting',
        seconds: (j['seconds'] as num?)?.toDouble(),
        startedAt: _time(j['startedAt'] as String?),
        log: j['log'] as String?,
      );
}

/// engine.py writes local time as 2026-11-10T20:00:00-0800.
DateTime? _time(String? s) {
  if (s == null) return null;
  final m = RegExp(r'^(.*[+-]\d\d)(\d\d)$').firstMatch(s);
  return DateTime.tryParse(m == null ? s : '${m[1]}:${m[2]}');
}

/// One chunk of the game (`status`'s chunkDetails): ten minutes of video
/// that go through the ball stage (finding the ball and who is who), then
/// the follow stage (the camera and the render).
class ChunkDetail {
  const ChunkDetail({
    required this.chunk,
    required this.startS,
    required this.seconds,
    required this.ball,
    required this.follow,
    this.ballAimPct,
    this.ballDetectedPct,
  });

  final int chunk;
  final double startS;
  final double seconds;
  final ChunkStage ball;
  final ChunkStage follow;
  final int? ballAimPct;
  final int? ballDetectedPct;

  factory ChunkDetail.fromJson(Map<String, Object?> j) => ChunkDetail(
        chunk: (j['chunk'] as num).toInt(),
        startS: (j['startS'] as num).toDouble(),
        seconds: (j['seconds'] as num).toDouble(),
        ball: ChunkStage.fromJson(((j['ball'] as Map?) ?? {}).cast()),
        follow: ChunkStage.fromJson(((j['follow'] as Map?) ?? {}).cast()),
        ballAimPct: (j['ballAimPct'] as num?)?.toInt(),
        ballDetectedPct: (j['ballDetectedPct'] as num?)?.toInt(),
      );

  static List<ChunkDetail> listOf(Object? j) => [
        for (final c in (j as List? ?? []))
          if (c is Map) ChunkDetail.fromJson(c.cast())
      ];
}

/// Where the engine thinks the ball may be in a frame, in image pixels.
class BallSuggestion {
  const BallSuggestion({required this.x, required this.y, this.conf, this.fromPath = false});
  final double x, y;
  final double? conf;
  final bool fromPath;
}

/// One frame of a ball label set.
class BallFrame {
  const BallFrame({
    required this.id,
    required this.image,
    required this.videoT,
    required this.width,
    required this.height,
    required this.suggestions,
    required this.answered,
  });

  final String id;

  /// The picture's file, absolute.
  final String image;

  /// Seconds into the game.
  final double videoT;
  final int width, height;
  final List<BallSuggestion> suggestions;
  final bool answered;
}

/// The user's label for one frame.
sealed class BallLabel {
  const BallLabel();
  Map<String, Object?> toJson();

  static BallLabel? fromJson(Object? j) {
    if (j is! Map) return null;
    return switch (j['status']) {
      'ball' => BallAt((j['x'] as num).toDouble(), (j['y'] as num).toDouble()),
      'none' => const NoBall(),
      'unsure' => const BallUnsure(),
      _ => null,
    };
  }
}

/// The match ball is here (image pixels).
class BallAt extends BallLabel {
  const BallAt(this.x, this.y);
  final double x, y;
  @override
  Map<String, Object?> toJson() => {
        'status': 'ball',
        'x': (x * 10).roundToDouble() / 10,
        'y': (y * 10).roundToDouble() / 10,
      };
}

/// The ball isn't in the picture.
class NoBall extends BallLabel {
  const NoBall();
  @override
  Map<String, Object?> toJson() => {'status': 'none'};
}

/// Can't tell.
class BallUnsure extends BallLabel {
  const BallUnsure();
  @override
  Map<String, Object?> toJson() => {'status': 'unsure'};
}

/// `<recording>/engine/labels/<set>/set.json` of kind ball, with the labels
/// given so far (answers.json beside it).
class BallLabelSet {
  const BallLabelSet({required this.name, required this.folder, required this.frames, required this.labels});

  /// e.g. `ball-1`: answers name it.
  final String name;
  final Directory folder;
  final List<BallFrame> frames;

  /// By frame id.
  final Map<String, BallLabel> labels;

  int get labelled => frames.where((f) => labels.containsKey(f.id)).length;
  bool get complete => frames.isNotEmpty && labelled == frames.length;

  static Future<BallLabelSet?> read(Directory folder) async {
    final f = File('${folder.path}/set.json');
    if (!await f.exists()) return null;
    final j = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    if (j['kind'] != 'ball') return null;
    final a = File('${folder.path}/answers.json');
    final given = await a.exists() ? (jsonDecode(await a.readAsString()) as Map).cast<String, Object?>() : const {};
    final labels = <String, BallLabel>{};
    for (final e in given.entries) {
      final l = BallLabel.fromJson(e.value);
      if (l != null) labels[e.key] = l;
    }
    return BallLabelSet(
      name: j['set'] as String,
      folder: folder,
      labels: labels,
      frames: [
        for (final it in (j['items'] as List? ?? []).cast<Map>())
          BallFrame(
            id: it['id'] as String,
            image: '${folder.path}/${it['image']}',
            videoT: (it['videoT'] as num).toDouble(),
            width: (it['width'] as num?)?.toInt() ?? 3840,
            height: (it['height'] as num?)?.toInt() ?? 2160,
            answered: it['answered'] == true,
            suggestions: [
              for (final s in (it['suggestions'] as List? ?? []).cast<Map>())
                BallSuggestion(
                  x: (s['x'] as num).toDouble(),
                  y: (s['y'] as num).toDouble(),
                  conf: (s['conf'] as num?)?.toDouble(),
                  fromPath: s['fromPath'] == true,
                )
            ],
          )
      ],
    );
  }

  /// The recording's ball sets, oldest first.
  static Future<List<BallLabelSet>> all(Directory recording) async {
    final root = Directory('${recording.path}/engine/labels');
    if (!await root.exists()) return [];
    final dirs = [
      await for (final d in root.list())
        if (d is Directory && RegExp(r'/ball-\d+$').hasMatch(d.path)) d
    ]..sort((a, b) => _n(a.path).compareTo(_n(b.path)));
    return [
      for (final d in dirs)
        if (await read(d) case final s?) s
    ];
  }

  static int _n(String path) => int.parse(path.substring(path.lastIndexOf('-') + 1));

  /// Writes [labels] as an engine-label-answers file for
  /// `osb-engine label <job> --answers <file>`, which stores them with the
  /// set in the formats training reads.
  Future<File> writeAnswers(Map<String, BallLabel> labels) async {
    final f = File('${folder.path}/app-answers.json');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'set': name,
      'ball': {for (final e in labels.entries) e.key: e.value.toJson()},
    }));
    return tmp.rename(f.path);
  }
}

/// The `status` line of `osb-engine status <job>`'s output, or null.
EngineEvent? statusLine(String stdout) =>
    stdout.split('\n').map(EngineEvent.parse).whereType<EngineEvent>().where((e) => e.event == 'status').firstOrNull;
