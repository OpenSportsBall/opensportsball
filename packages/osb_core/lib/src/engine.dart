// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Driving the processing engine (osb-engine, opensportsball-processing's
/// engine.py) as a separate program, only through files and its progress
/// lines (docs/LICENSING.md): the job it is given, the questions it asks,
/// the answers it is given back, and JSON events on stdout
/// (shared/schemas/engine-*.schema.json).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// engine.py's exit codes.
enum EngineExit {
  ok(0),
  badInput(2),
  needsAnswers(3),
  failed(4),
  stopped(130),
  other(-1);

  const EngineExit(this.code);
  final int code;

  static EngineExit of(int code) => values.firstWhere((e) => e.code == code, orElse: () => other);
}

/// One line of the engine's stdout (engine-event.schema.json). Unknown
/// events and fields are kept in [raw] and otherwise ignored.
class EngineEvent {
  const EngineEvent(this.raw);
  final Map<String, Object?> raw;

  String get event => raw['event'] as String? ?? '';
  String? get step => raw['step'] as String?;
  String? get status => raw['status'] as String?;
  String? get stage => raw['stage'] as String?;
  double? get fraction => (raw['fraction'] as num?)?.toDouble();
  double? get etaS => (raw['etaS'] as num?)?.toDouble();
  double? get elapsedS => (raw['elapsedS'] as num?)?.toDouble();
  String? get code => raw['code'] as String?;
  String? get message => raw['message'] as String?;
  String? get log => raw['log'] as String?;
  String? get output => raw['output'] as String?;

  /// The 1440p copy for YouTube, when the job asked for one and it is made.
  String? get youtubeOutput => raw['youtubeOutput'] as String?;
  List<String> get pending => [for (final p in (raw['pending'] as List? ?? [])) '$p'];

  /// A line that isn't an event (a stray print), or null.
  static EngineEvent? parse(String line) {
    try {
      final j = jsonDecode(line);
      if (j is Map && j['event'] is String) return EngineEvent(j.cast());
    } on FormatException {
      // not JSON
    }
    return null;
  }
}

/// The engine-job.schema.json file for one recording folder. With
/// [youtubeCopy], a 1080p game.mp4 gets a 1440p game-youtube.mp4 beside it
/// (a 1440p game.mp4 is that file already).
Map<String, Object?> engineJob(String recordingFolder, {int height = 1080, bool youtubeCopy = false, int? maxChunks}) => {
      'schemaVersion': 1,
      'recording': recordingFolder,
      'output': {'height': height, if (youtubeCopy && height < 1440) 'youtubeCopy': true},
      if (maxChunks != null) 'options': {'maxChunks': maxChunks},
    };

/// How the app runs the engine: the packaged launcher (`osb-engine/osb-engine`),
/// or for development a Python and engine.py (`uv run` style commands).
class EngineCommand {
  const EngineCommand(this.executable, [this.prefix = const []]);

  /// The packaged engine's launcher.
  factory EngineCommand.packaged(String launcher) => EngineCommand(launcher);

  final String executable;
  final List<String> prefix;

  List<String> args(List<String> rest) => [...prefix, ...rest];
}

/// One running engine command.
class EngineRun {
  EngineRun._(this._process, this.events, this.exitCode, this.stderrTail);

  final Process _process;

  /// Its events, in order; closes when the process ends.
  final Stream<EngineEvent> events;

  /// The exit, once it has ended.
  final Future<EngineExit> exitCode;

  /// The last lines it wrote to stderr (for an error report).
  final List<String> stderrTail;

  int get pid => _process.pid;

  /// Asks it to stop (SIGINT: the engine stops its step's whole process
  /// group and exits 130). The same command later carries on.
  bool stop() => _process.kill(ProcessSignal.sigint);

  /// Kills it outright, when [stop] wasn't enough.
  bool kill() => _process.kill(ProcessSignal.sigkill);

  static Future<EngineRun> start(EngineCommand cmd, List<String> args, {String? workingDirectory}) async {
    final p = await Process.start(cmd.executable, cmd.args(args), workingDirectory: workingDirectory);
    final controller = StreamController<EngineEvent>();
    final tail = <String>[];
    final out = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final e = EngineEvent.parse(line);
      if (e != null) controller.add(e);
    }).asFuture<void>();
    final err = p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      tail.add(line);
      if (tail.length > 40) tail.removeAt(0);
    }).asFuture<void>();
    final exit = () async {
      final code = await p.exitCode;
      await Future.wait([out, err]);
      await controller.close();
      return EngineExit.of(code);
    }();
    return EngineRun._(p, controller.stream, exit, tail);
  }
}

/// A point in panorama degrees.
typedef Deg = ({double yaw, double pitch});

Deg _deg(Object? v) {
  if (v is List) return (yaw: (v[0] as num).toDouble(), pitch: (v[1] as num).toDouble());
  final m = (v as Map).cast<String, Object?>();
  return (yaw: (m['yaw'] as num).toDouble(), pitch: (m['pitch'] as num).toDouble());
}

/// The background panorama's pixel grid: x = (yaw - yawRange[0]) / degPerPx.
class Panorama {
  const Panorama(
      {required this.degPerPx, required this.yaw0, required this.yaw1, required this.pitch0, required this.pitch1});
  final double degPerPx;
  final double yaw0, yaw1, pitch0, pitch1;

  double get width => (yaw1 - yaw0) / degPerPx;
  double get height => (pitch1 - pitch0) / degPerPx;

  ({double x, double y}) toPx(Deg d) => (x: (d.yaw - yaw0) / degPerPx, y: (d.pitch - pitch0) / degPerPx);
  Deg toDeg(double x, double y) => (yaw: yaw0 + x * degPerPx, pitch: pitch0 + y * degPerPx);

  static Panorama? fromJson(Object? j) {
    if (j is! Map) return null;
    final y = j['yawRange'] as List, p = j['pitchRange'] as List;
    return Panorama(
      degPerPx: (j['degPerPx'] as num).toDouble(),
      yaw0: (y[0] as num).toDouble(),
      yaw1: (y[1] as num).toDouble(),
      pitch0: (p[0] as num).toDouble(),
      pitch1: (p[1] as num).toDouble(),
    );
  }
}

class PitchQuestion {
  const PitchQuestion({
    required this.round,
    required this.status,
    required this.background,
    required this.overlay,
    required this.panorama,
    required this.lines,
    required this.goals,
    required this.points,
    required this.approveAllowed,
    this.problem,
    this.fit = const {},
  });

  final int round;
  final String status;

  /// Relative to the recording folder.
  final String background;
  final String? overlay;
  final Panorama? panorama;
  final List<List<Deg>> lines;
  final List<List<Deg>> goals;

  /// Named keypoints where the fit puts them.
  final Map<String, Deg> points;
  final bool approveAllowed;
  final String? problem;
  final Map<String, Object?> fit;

  bool get pending => status == 'pending';

  factory PitchQuestion.fromJson(Map<String, Object?> j) => PitchQuestion(
        round: (j['round'] as num).toInt(),
        status: j['status'] as String,
        background: j['background'] as String,
        overlay: j['overlay'] as String?,
        panorama: Panorama.fromJson(j['panorama']),
        lines: [
          for (final l in (j['lines'] as List? ?? [])) [for (final p in l as List) _deg(p)]
        ],
        goals: [
          for (final g in (j['goals'] as List? ?? []))
            if (g is Map && g['deg'] is List) [for (final p in g['deg'] as List) _deg(p)]
        ],
        points: {for (final e in ((j['points'] as Map?) ?? {}).entries) '${e.key}': _deg(e.value)},
        approveAllowed: j['approveAllowed'] as bool? ?? true,
        problem: j['problem'] as String?,
        fit: ((j['fit'] as Map?) ?? {}).cast(),
      );
}

class CamerasQuestion {
  const CamerasQuestion(
      {required this.round, required this.status, required this.mainLeft, required this.secondaryLeft, this.reason});
  final int round;
  final String status;
  final String mainLeft;
  final String secondaryLeft;
  final String? reason;

  bool get pending => status == 'pending';

  factory CamerasQuestion.fromJson(Map<String, Object?> j) {
    final p = (j['panoramas'] as Map).cast<String, Object?>();
    return CamerasQuestion(
      round: (j['round'] as num).toInt(),
      status: j['status'] as String,
      mainLeft: p['mainLeft'] as String,
      secondaryLeft: p['secondaryLeft'] as String,
      reason: j['reason'] as String?,
    );
  }
}

/// `<recording>/engine/questions.json`.
class EngineQuestions {
  const EngineQuestions({required this.pending, this.pitch, this.cameras});
  final List<String> pending;
  final PitchQuestion? pitch;
  final CamerasQuestion? cameras;

  factory EngineQuestions.fromJson(Map<String, Object?> j) => EngineQuestions(
        // A game prepared before the kit check was removed may still list it:
        // the engine no longer waits for it.
        pending: [
          for (final p in (j['pending'] as List? ?? []))
            if (p != 'kits') '$p'
        ],
        pitch: j['pitch'] is Map ? PitchQuestion.fromJson((j['pitch'] as Map).cast()) : null,
        cameras: j['cameras'] is Map ? CamerasQuestion.fromJson((j['cameras'] as Map).cast()) : null,
      );

  static Future<EngineQuestions?> read(Directory recording) async {
    final f = File('${recording.path}/engine/questions.json');
    if (!await f.exists()) return null;
    return EngineQuestions.fromJson((jsonDecode(await f.readAsString()) as Map).cast());
  }
}

/// What the user did on the pitch check.
sealed class PitchPoint {
  const PitchPoint();
  Map<String, Object?> toJson();
}

class MovedPoint extends PitchPoint {
  const MovedPoint(this.at);
  final Deg at;
  @override
  Map<String, Object?> toJson() => {'yaw': _r(at.yaw), 'pitch': _r(at.pitch)};
}

class FromFitPoint extends PitchPoint {
  const FromFitPoint();
  @override
  Map<String, Object?> toJson() => {'fromFit': true};
}

class SkippedPoint extends PitchPoint {
  const SkippedPoint();
  @override
  Map<String, Object?> toJson() => {'skipped': true};
}

double _r(double v) => (v * 1000).roundToDouble() / 1000;

/// engine-answers.schema.json. The whole file is rewritten and passed again
/// each time; answers to an older round are ignored by the engine.
class EngineAnswers {
  EngineAnswers();

  Map<String, Object?>? pitch;
  Map<String, Object?>? cameras;

  factory EngineAnswers.fromJson(Map<String, Object?> j) => EngineAnswers()
    ..pitch = (j['pitch'] as Map?)?.cast()
    ..cameras = (j['cameras'] as Map?)?.cast();

  Map<String, Object?> toJson() => {
        if (cameras != null) 'cameras': cameras,
        if (pitch != null) 'pitch': pitch,
      };

  void approvePitch(int round, {required bool share}) => pitch = {'round': round, 'approve': true, 'share': share};

  void markPitch(int round, Map<String, PitchPoint> points, {required bool share}) => pitch = {
        'round': round,
        'points': {for (final e in points.entries) e.key: e.value.toJson()},
        'share': share,
      };

  void answerCameras(int round, {required bool mainLeft}) =>
      cameras = {'round': round, 'leftPhone': mainLeft ? 'main' : 'secondary'};

  static File fileIn(Directory recording) => File('${recording.path}/engine/answers.json');

  static Future<EngineAnswers> read(Directory recording) async {
    final f = fileIn(recording);
    if (!await f.exists()) return EngineAnswers();
    return EngineAnswers.fromJson((jsonDecode(await f.readAsString()) as Map).cast());
  }

  Future<File> write(Directory recording) async {
    final f = fileIn(recording);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(toJson()));
    return tmp.rename(f.path);
  }
}
