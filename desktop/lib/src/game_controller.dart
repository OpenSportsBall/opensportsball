// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// One recording on its way from the cloud to game.mp4 on this Mac
/// (docs/MAC-APP-PLAN.md, "The app, step by step"): download, prepare, the
/// checks, the overnight run. Where it stands is worked out from its folder
/// and `osb-engine status`, so a quit, a crash or a reboot loses nothing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:osb_core/osb_core.dart';

import 'services.dart';

enum Phase {
  loading,
  needsDownload,
  downloading,
  needsPrepare,
  preparing,
  questions,
  readyToRun,
  running,
  paused,
  done,
}

/// What the engine's steps are called on screen.
const stepNames = {
  'verify-footage': 'Checking the footage',
  'sync': 'Syncing the two phones and stitching their views',
  'pitch': 'Fitting the pitch',
  'goals': 'Finding the goals',
  'kit-sample': 'Finding people on the pitch',
  'kits': 'Grouping people by kit',
  'pitch-review': 'Drawing the pitch for checking',
  'cameras': 'Placing the cameras',
  'game': 'Processing the game',
  'mux': 'Adding the sound',
  'cleanup': 'Tidying up',
};

/// How long each `prepare` step usually takes, from two games on an M-series
/// Mac (rec3 and a Pixel + iPhone game, 4 segments a phone): shown beside
/// the time so far, so a long step doesn't look stuck.
const usualStepSeconds = {
  'verify-footage': 30,
  'sync': 60,
  'pitch': 180,
  'goals': 30,
  'kit-sample': 450,
  'kits': 120,
  'pitch-review': 30,
};

String stepName(String? step) => stepNames[step] ?? (step == null ? 'Working' : step.replaceAll('_', ' '));

/// The folder a game's recording goes in: `<work>/<date time> <game id>`.
String recordingFolder(String work, GameSummary g, String recordingId, {required bool onlyRecording}) {
  final t = g.when.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final name = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)} ${g.gameId.substring(0, 8)}';
  return onlyRecording ? '$work/$name' : '$work/$name/${recordingId.substring(0, 8)}';
}

class GameController extends ChangeNotifier {
  GameController({required this.summary, required this.session, required this.settings, required this.onSignedOut});

  final GameSummary summary;
  final Session session;
  final Settings settings;
  final VoidCallback onSignedOut;

  Phase phase = Phase.loading;
  Game? game;
  Recording? recording;
  Directory? folder;
  EngineQuestions? questions;
  List<Check> checks = const [];

  /// What it's doing now, for the progress line.
  String? activity;

  /// The engine step under way: its name, when it started and its log.
  String? step;
  DateTime? stepStartedAt;
  String? stepLog;
  double? fraction;
  double? etaS;
  DownloadProgress? download;
  String? error;
  String? errorLog;
  String? output;
  bool pausedForBattery = false;
  bool _disposed = false;

  FootageDownloader? _downloader;
  EngineRun? _engine;
  Process? _caffeinate;
  Timer? _powerTimer;

  bool get busy => phase == Phase.downloading || phase == Phase.preparing || phase == Phase.running;
  File get _job => File('${folder!.path}/job.json');

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void _fail(String message, {String? log}) {
    error = message;
    errorLog = log;
    notifyListeners();
  }

  Future<T?> _api<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on SignedOut {
      onSignedOut();
    } on OsbException catch (e) {
      _fail(e.message);
    }
    return null;
  }

  /// Finds the recording and works out where it stands.
  Future<void> open() async {
    phase = Phase.loading;
    error = null;
    notifyListeners();
    final g = await _api(() => session.game(summary.gameId));
    if (g == null) return;
    game = g;
    final ready = g.recordings.where((r) => r.ready).toList();
    if (ready.isEmpty) {
      recording = g.recordings.isEmpty ? null : g.recordings.first;
      phase = Phase.needsDownload;
      _fail(
        g.recordings.isEmpty
            ? 'This game has no recordings.'
            : 'This game is still uploading from the phones. It can be processed once both have finished.',
      );
      return;
    }
    recording = ready.first;
    folder = Directory(
      recordingFolder(settings.workFolder, summary, recording!.recordingId, onlyRecording: g.recordings.length == 1),
    );
    await _refresh();
  }

  Future<void> _writeJob() async {
    await folder!.create(recursive: true);
    await _job.writeAsString(
      jsonEncode(engineJob(folder!.path, height: settings.outputHeight, maxChunks: settings.maxChunks)),
    );
  }

  /// Works out the phase from the folder and the engine's status.
  Future<void> _refresh() async {
    await _stopStale();
    final complete = await FootageDownloader.isComplete(folder!);
    if (!complete) {
      phase = Phase.needsDownload;
      await _runChecks();
      notifyListeners();
      return;
    }
    final engine = settings.findEngine();
    if (engine == null) {
      phase = Phase.needsPrepare;
      _fail('No processing engine found. Choose it in Settings.');
      return;
    }
    await _writeJob();
    final r = await Process.run(engine, ['status', _job.path]);
    final status = (r.stdout as String)
        .split('\n')
        .map(EngineEvent.parse)
        .whereType<EngineEvent>()
        .where((e) => e.event == 'status')
        .firstOrNull;
    if (status == null) {
      phase = Phase.needsPrepare;
    } else if (status.output != null) {
      output = status.output;
      phase = Phase.done;
    } else if (status.raw['prepared'] != true) {
      phase = Phase.needsPrepare;
    } else {
      await _loadQuestions();
    }
    await _runChecks();
    notifyListeners();
  }

  Future<void> _runChecks() async {
    final bytes = recording?.expectedBytes ?? 0;
    var have = 0;
    if (await FootageDownloader.isComplete(folder!)) have = bytes;
    checks = await preflight(workFolder: settings.workFolder, footageBytes: bytes, haveBytes: have);
  }

  Future<void> _loadQuestions() async {
    questions = await EngineQuestions.read(folder!);
    // A new round's pictures have the same names: drop the cached ones.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    phase = (questions?.pending.isNotEmpty ?? true) ? Phase.questions : Phase.readyToRun;
  }

  // --- download ---------------------------------------------------------------

  Future<void> startDownload() async {
    if (busy || recording == null) return;
    error = null;
    phase = Phase.downloading;
    activity = 'Downloading the footage';
    notifyListeners();
    final rec = recording!;
    _downloader = FootageDownloader(
      folder: folder!,
      client: session.client,
      maxSegments: settings.maxSegments,
      links: () => session.downloads(summary.gameId, rec.recordingId),
    );
    try {
      await _downloader!.run(
        onProgress: (p) {
          download = p;
          fraction = p.fraction;
          etaS = p.bytesPerSecond == null || p.bytesPerSecond == 0
              ? null
              : (p.totalBytes - p.doneBytes) / p.bytesPerSecond!;
          notifyListeners();
        },
      );
      _downloader = null;
      fraction = null;
      etaS = null;
      await _refresh();
      if (phase == Phase.needsPrepare) await prepare();
    } on DownloadStopped {
      phase = Phase.needsDownload;
      notifyListeners();
    } on SignedOut {
      phase = Phase.needsDownload;
      onSignedOut();
    } on FootageCorrupt catch (e) {
      phase = Phase.needsDownload;
      _fail('$e');
    } on OsbException catch (e) {
      phase = Phase.needsDownload;
      _fail(e.message);
    } on FileSystemException catch (e) {
      phase = Phase.needsDownload;
      _fail('Could not write the footage (${e.osError?.message ?? e.message}). Is there room on the disk?');
    } finally {
      _downloader = null;
    }
  }

  // --- the engine -------------------------------------------------------------

  File get _pidFile => File('${folder!.path}/engine/app-run.pid');

  /// An engine left running by a crashed app would race a new one: stop it.
  Future<void> _stopStale() async {
    if (_engine != null) return;
    try {
      final pid = int.parse((await _pidFile.readAsString()).trim());
      final alive = (await Process.run('/bin/kill', ['-0', '$pid'])).exitCode == 0;
      if (alive) {
        Process.killPid(pid, ProcessSignal.sigint);
        for (var i = 0; i < 100 && (await Process.run('/bin/kill', ['-0', '$pid'])).exitCode == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      await _pidFile.delete();
    } on Object {
      // none
    }
  }

  Future<EngineExit?> _runEngine(List<String> args, {required void Function(EngineEvent) onEvent}) async {
    final engine = settings.findEngine();
    if (engine == null) {
      _fail('No processing engine found. Choose it in Settings.');
      return null;
    }
    await _writeJob();
    error = null;
    errorLog = null;
    final run = await EngineRun.start(EngineCommand.packaged(engine), args);
    _engine = run;
    await _pidFile.parent.create(recursive: true);
    await _pidFile.writeAsString('${run.pid}');
    // Keep the Mac awake while it works (not the display).
    _caffeinate = await Process.start('/usr/bin/caffeinate', ['-i', '-w', '${run.pid}']);
    String? failure, failureLog;
    final sub = run.events.listen((e) {
      if (e.event == 'error') {
        failure = e.message;
        failureLog = e.log;
      }
      onEvent(e);
    });
    final exit = await run.exitCode;
    await sub.cancel();
    _engine = null;
    _caffeinate?.kill();
    _caffeinate = null;
    try {
      await _pidFile.delete();
    } on Object {
      // gone
    }
    if (exit == EngineExit.badInput || exit == EngineExit.failed || exit == EngineExit.other) {
      _fail(
        failure ?? 'The engine stopped with an error (${run.stderrTail.lastOrNull ?? exit.name}).',
        log: failureLog,
      );
    }
    return exit;
  }

  void _onStep(EngineEvent e) {
    if (e.event == 'step' && e.status == 'started') {
      activity = stepName(e.step);
      step = e.step;
      stepStartedAt = DateTime.now();
      final log = e.log;
      stepLog = log == null ? null : (log.startsWith('/') ? log : '${folder!.path}/$log');
      notifyListeners();
    } else if (e.event == 'progress') {
      activity = stepName(e.stage);
      fraction = e.fraction;
      etaS = e.etaS;
      notifyListeners();
    } else if (e.event == 'done' && e.output != null) {
      output = e.output;
    }
  }

  Future<void> prepare() async {
    if (busy) return;
    phase = Phase.preparing;
    activity = 'Getting ready';
    fraction = null;
    etaS = null;
    notifyListeners();
    final answers = EngineAnswers.fileIn(folder!);
    final exit = await _runEngine([
      'prepare',
      _job.path,
      if (await answers.exists()) ...['--answers', answers.path],
    ], onEvent: _onStep);
    if (exit == EngineExit.ok) {
      await _loadQuestions();
    } else {
      phase = await File('${folder!.path}/engine/questions.json').exists() ? Phase.questions : Phase.needsPrepare;
      if (phase == Phase.questions) questions = await EngineQuestions.read(folder!);
    }
    notifyListeners();
  }

  /// Saves an answer and has the engine apply it (it may ask again).
  Future<void> answer(void Function(EngineAnswers) change) async {
    final a = await EngineAnswers.read(folder!);
    change(a);
    await a.write(folder!);
    await prepare();
  }

  Future<void> run() async {
    if (busy) return;
    phase = Phase.running;
    pausedForBattery = false;
    activity = 'Processing the game';
    fraction = null;
    etaS = null;
    notifyListeners();
    _powerTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkPower());
    final exit = await _runEngine([
      'run',
      _job.path,
      '--answers',
      EngineAnswers.fileIn(folder!).path,
    ], onEvent: _onStep);
    _powerTimer?.cancel();
    _powerTimer = null;
    if (exit == EngineExit.ok) {
      phase = Phase.done;
    } else if (exit == EngineExit.needsAnswers) {
      await _loadQuestions();
    } else if (exit == EngineExit.stopped) {
      phase = pausedForBattery ? Phase.paused : Phase.readyToRun;
      if (pausedForBattery) _powerTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkPower());
    } else {
      phase = Phase.readyToRun;
    }
    notifyListeners();
  }

  /// Pauses on battery (the run carries on where it was once plugged in).
  Future<void> _checkPower() async {
    final mains = await onMains();
    if (phase == Phase.running && mains == false) {
      pausedForBattery = true;
      _engine?.stop();
    } else if (phase == Phase.paused && mains == true) {
      _powerTimer?.cancel();
      _powerTimer = null;
      await run();
    }
  }

  /// Stops whatever it's doing; the same step carries on later.
  void stop() {
    pausedForBattery = false;
    _downloader?.stop();
    _engine?.stop();
    if (phase == Phase.paused) {
      _powerTimer?.cancel();
      _powerTimer = null;
      phase = Phase.readyToRun;
      notifyListeners();
    }
  }

  /// Stops the engine and waits for it (the app is quitting).
  Future<void> shutdown() async {
    _downloader?.stop();
    final e = _engine;
    if (e == null) return;
    e.stop();
    await e.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        e.kill();
        return EngineExit.stopped;
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _powerTimer?.cancel();
    super.dispose();
  }
}
