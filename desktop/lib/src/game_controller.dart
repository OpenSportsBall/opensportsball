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
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:osb_core/osb_core.dart';
import 'package:osb_core/osb_core.dart' as osb show withdrawShared;

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
  'youtube': 'Making the copy for YouTube',
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

/// How long one chunk (10 minutes of video) of `run` usually takes on an
/// M-series Mac: 52.6 min for rec3's first chunk, 58.1 for a Pixel + iPhone
/// game's. Used for an estimate until the engine has one of its own (after
/// its first chunk).
const usualChunkSeconds = 3320;

String stepName(String? step) => stepNames[step] ?? (step == null ? 'Working' : step.replaceAll('_', ' '));

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

  /// `run`'s chunk count and time so far, from its progress lines.
  int? chunks;
  double? runElapsedS;

  /// The engine's estimate, or until it has one (before its first chunk is
  /// done) one from the chunk count and [usualChunkSeconds].
  bool get etaIsEstimate => etaS == null && chunks != null;

  double? get shownEtaS {
    if (etaS != null) return etaS;
    if (chunks == null) return null;
    return math.max(60, chunks! * usualChunkSeconds - (runElapsedS ?? 0)).toDouble();
  }

  /// The engine's fraction once it moves; before that, time so far against
  /// the estimate (never past 95%, so a slow Mac doesn't look finished).
  double? get shownFraction {
    if ((fraction ?? 0) > 0 || !etaIsEstimate) return fraction;
    return math.min(0.95, (runElapsedS ?? 0) / (chunks! * usualChunkSeconds));
  }

  /// How the camera is doing with the ball, from the engine after each
  /// chunk (and from its status when the game is opened).
  BallCheck? ball;

  /// The models don't know this game's ball: the video follows the play
  /// less closely, and ball labels are offered.
  bool get ballLow => ball?.low == true;

  /// Each chunk's stages, for the details view ([loadChunkDetails]).
  List<ChunkDetail> chunkDetails = const [];

  DownloadProgress? download;
  String? error;
  String? errorLog;
  String? output;

  /// The 1440p copy for YouTube, once made (game.mp4 itself when that is
  /// 1440p already).
  String? youtubeOutput;

  /// The game is done and Settings ask for a YouTube copy it doesn't have
  /// (the setting was switched on later, or the copy failed): [run] makes
  /// just the copy.
  bool get youtubeCopyMissing => phase == Phase.done && settings.youtubeCopy && youtubeOutput == null;
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

  /// The phones haven't finished uploading, as of the last [open]. The
  /// games list asks again on refresh ([GamesScreenState]).
  bool awaitingUpload = false;

  /// Finds the recording and works out where it stands.
  Future<void> open() async {
    phase = Phase.loading;
    error = null;
    notifyListeners();
    final g = await _api(() => session.game(summary.gameId));
    if (g == null) return;
    game = g;
    final ready = g.recordings.where((r) => r.ready).toList();
    awaitingUpload = ready.isEmpty && g.recordings.isNotEmpty;
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
    // Where it was put before, if that's still there (the work folder may
    // have been changed since); else where it goes now.
    final known = settings.knownGame(recording!.recordingId);
    if (known != null && Directory(known.folder).existsSync()) {
      folder = Directory(known.folder);
      _knownMaxChunks = known.maxChunks;
    } else {
      folder = Directory(
        recordingFolder(settings.workFolder, summary, recording!.recordingId, onlyRecording: g.recordings.length == 1),
      );
      _knownMaxChunks = null;
    }
    await _refresh();
  }

  /// The maxChunks this game was last processed with: kept while the
  /// setting is unset, so a shortened game doesn't turn into an unfinished
  /// whole one.
  int? _knownMaxChunks;
  int? get _maxChunks => settings.maxChunks ?? _knownMaxChunks;

  Future<void> _remember() =>
      settings.rememberGame(recording!.recordingId, KnownGame(folder!.path, maxChunks: _maxChunks));

  Future<void> _writeJob() async {
    await folder!.create(recursive: true);
    await _job.writeAsString(
      jsonEncode(
        engineJob(
          folder!.path,
          height: settings.outputHeight,
          youtubeCopy: settings.youtubeCopy,
          maxChunks: _maxChunks,
        ),
      ),
    );
    await _remember();
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
    final status = statusLine(r.stdout as String);
    if (status != null) _takeStatus(status);
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
    // What was agreed and not sent yet (the app was quit, or offline).
    if (phase == Phase.readyToRun || phase == Phase.done) unawaited(sendAgreed());
  }

  void _takeStatus(EngineEvent status) {
    ball = BallCheck.of(status.raw) ?? ball;
    chunkDetails = ChunkDetail.listOf(status.raw['chunkDetails']);
    youtubeOutput = status.youtubeOutput;
  }

  /// Asks the engine where each chunk stands (it reads its own files, so
  /// this is fine while it is processing).
  Future<void> loadChunkDetails() async {
    final engine = settings.findEngine();
    if (engine == null || folder == null || !await _job.exists()) return;
    final r = await Process.run(engine, ['status', _job.path]);
    final status = statusLine(r.stdout as String);
    if (status == null) return;
    _takeStatus(status);
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
    await _remember(); // a part-done download is found again too
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
      chunks = (e.raw['chunks'] as num?)?.toInt() ?? chunks;
      runElapsedS = e.elapsedS ?? runElapsedS;
      notifyListeners();
    } else if (e.event == 'ball') {
      ball = BallCheck.of(e.raw) ?? ball;
      notifyListeners();
      unawaited(loadChunkDetails());
    } else if (e.event == 'done' && e.output != null) {
      output = e.output;
      youtubeOutput = e.youtubeOutput;
      ball = BallCheck.of(e.raw) ?? ball;
    }
  }

  // --- sharing ----------------------------------------------------------------

  /// What has been sent from this game, and whether the user withdrew it.
  SentRecord? sent;

  /// The result being sent now, and how far.
  SendProgress? sending;
  String? shareError;
  Future<void>? _sendingNow;

  List<String> get sharedNames => sent?.names ?? const [];
  bool get shareStopped => sent?.stopped ?? false;

  /// Sends what the user agreed to share and hasn't been sent as it now
  /// stands: the pitch map (its check's switch) and the ball sets with
  /// marks. The engine lists them (`share`); nothing is
  /// sent before the sharing wording is agreed, or after this game's
  /// contributions were withdrawn. Never throws: [shareError] says what
  /// went wrong, and the next call carries on.
  Future<void> sendAgreed() => _sendingNow ??= _sendAgreed().whenComplete(() => _sendingNow = null);

  Future<void> _sendAgreed() async {
    final dir = folder, rec = recording;
    if (dir == null || rec == null) return;
    try {
      sent = await SentRecord.read(dir);
      if (!settings.sharingAgreed || shareStopped || !await _job.exists()) return;
      final names = <String>[];
      final failure = await _sideCommand(
        ['share', _job.path],
        onEvent: (e) {
          if (e.event == 'share' && e.raw['path'] != null) names.add('${e.raw['name']}');
        },
      );
      if (failure != null || names.isEmpty) return; // nothing to share yet
      shareError = null;
      await sendShared(
        session: session,
        recording: dir,
        gameId: summary.gameId,
        recordingId: rec.recordingId,
        names: names,
        onProgress: (p) {
          sending = p;
          notifyListeners();
        },
      );
    } on SignedOut {
      onSignedOut();
    } on OsbException catch (e) {
      shareError = e.message;
    } on FileSystemException catch (e) {
      shareError = 'A file to share couldn’t be read (${e.osError?.message ?? e.message}).';
    } on Object catch (e) {
      // Sending runs on its own, beside the game: whatever goes wrong is said here, not thrown.
      shareError = 'Sharing went wrong ($e).';
    } finally {
      sending = null;
      try {
        sent = await SentRecord.read(dir);
      } on FileSystemException {
        // the folder went away
      }
      notifyListeners();
    }
  }

  /// Withdraws everything sent from this game, for good, and stops sending
  /// from it.
  Future<void> withdrawShared() async {
    final dir = folder;
    if (dir == null) return;
    await _sendingNow;
    shareError = null;
    try {
      await osb.withdrawShared(session: session, recording: dir);
    } on SignedOut {
      onSignedOut();
    } on OsbException catch (e) {
      shareError = e.message;
    }
    sent = await SentRecord.read(dir);
    notifyListeners();
  }

  /// Shares this game again after a withdrawal.
  Future<void> shareAgain() async {
    final dir = folder;
    if (dir == null) return;
    await resumeSharing(dir);
    await sendAgreed();
  }

  // --- ball labels ------------------------------------------------------------

  /// A short engine command beside whatever else is running (`label` and
  /// `share` only read the game's files and write under engine/labels and
  /// engine/share). Returns what went wrong, or null.
  Future<String?> _sideCommand(List<String> args, {void Function(EngineEvent)? onEvent}) async {
    final engine = settings.findEngine();
    if (engine == null) return 'No processing engine found. Choose it in Settings.';
    final run = await EngineRun.start(EngineCommand.packaged(engine), args);
    String? failure;
    final sub = run.events.listen((e) {
      if (e.event == 'error') failure = e.message;
      onEvent?.call(e);
    });
    final exit = await run.exitCode;
    await sub.cancel();
    if (exit == EngineExit.ok) return null;
    return failure ?? 'The engine stopped with an error (${run.stderrTail.lastOrNull ?? exit.name}).';
  }

  /// The ball frames to label: the set already started, else a new one the
  /// engine picks from the chunks it has been through (a minute or two).
  /// Throws [OsbException] with what went wrong.
  Future<BallLabelSet> ballSet() async {
    final sets = await BallLabelSet.all(folder!);
    if (sets.isNotEmpty && !sets.last.complete) return sets.last;
    final failure = await _sideCommand(['label', _job.path, 'ball']);
    if (failure != null) throw OsbException(failure);
    final made = await BallLabelSet.all(folder!);
    if (made.isEmpty) throw const OsbException('The engine made no frames to label.');
    return made.last;
  }

  /// Stores [labels] with the set (the engine writes them in the formats
  /// training reads) and sends the set as it now stands. Returns the set.
  Future<BallLabelSet> saveBallLabels(BallLabelSet set, Map<String, BallLabel> labels) async {
    if (labels.isNotEmpty) {
      final file = await set.writeAnswers(labels);
      final failure = await _sideCommand(['label', _job.path, '--answers', file.path]);
      if (failure != null) throw OsbException(failure);
      unawaited(sendAgreed());
    }
    return (await BallLabelSet.read(set.folder)) ?? set;
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
      if (phase == Phase.readyToRun) unawaited(sendAgreed()); // the checks are answered
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
    final wasDone = phase == Phase.done; // only the YouTube copy is to be made
    await _writeJob(); // what Settings say now (the video size, the YouTube copy)
    phase = Phase.running;
    pausedForBattery = false;
    activity = 'Processing the game';
    fraction = null;
    etaS = null;
    chunks = null;
    runElapsedS = null;
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
      unawaited(sendAgreed());
    } else if (exit == EngineExit.needsAnswers) {
      await _loadQuestions();
    } else if (exit == EngineExit.stopped) {
      phase = pausedForBattery ? Phase.paused : Phase.readyToRun;
      if (pausedForBattery) _powerTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkPower());
    } else {
      phase = wasDone ? Phase.done : Phase.readyToRun;
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

  // --- deleting from this Mac -------------------------------------------------

  /// The record of what was shared from this game: kept through
  /// [deleteLocal], so it can still be withdrawn and isn't sent twice.
  File? get _sentFile {
    final f = SentRecord.fileIn(folder!);
    return f.existsSync() ? f : null;
  }

  /// This game has files on this Mac to delete (more than the record of
  /// what was shared).
  bool get hasLocalFiles {
    final dir = folder;
    if (dir == null || !dir.existsSync()) return false;
    final kept = _sentFile?.path;
    try {
      return dir
          .listSync(recursive: kept != null, followLinks: false)
          .any((e) => e.path != kept && (e is! Directory || kept == null || !kept.startsWith('${e.path}/')));
    } on FileSystemException {
      return false;
    }
  }

  /// Nothing is working on the game's folder.
  bool get canDeleteLocal => !busy && phase != Phase.paused && phase != Phase.loading && hasLocalFiles;

  /// The game video is in the game's folder: [deleteLocal] deletes it too.
  bool get videoInFolder =>
      folder != null && [output, youtubeOutput].any((o) => o != null && o.startsWith('${folder!.path}/'));

  /// How much of this Mac's disk the game's folder takes.
  Future<int> localBytes() async {
    var n = 0;
    try {
      await for (final e in folder!.list(recursive: true, followLinks: false)) {
        if (e is File) n += await e.length();
      }
    } on FileSystemException {
      // being deleted
    }
    return n;
  }

  /// Deletes the game's folder from this Mac, for good: the footage, the
  /// engine's work and the game video. What's in the account isn't
  /// touched, so the game can be downloaded and processed again. The record
  /// of what was shared stays.
  Future<void> deleteLocal() async {
    final dir = folder;
    if (dir == null || !canDeleteLocal) return;
    phase = Phase.loading;
    error = null;
    errorLog = null;
    notifyListeners();
    await _sendingNow;
    await _stopStale();
    String? failure;
    try {
      final kept = _sentFile?.path;
      Future<void> clear(Directory d) async {
        await for (final e in d.list(followLinks: false)) {
          if (e.path == kept) continue;
          if (e is Directory && kept != null && kept.startsWith('${e.path}/')) {
            await clear(e);
          } else {
            await e.delete(recursive: true);
          }
        }
      }

      await clear(dir);
      if (kept == null) await dir.delete();
    } on FileSystemException catch (e) {
      failure = 'Not all of it could be deleted (${e.osError?.message ?? e.message}).';
    }
    // It starts again as a whole game, where the work folder now is.
    _knownMaxChunks = null;
    if (dir.existsSync()) {
      await _remember();
    } else {
      await settings.forgetGame(recording!.recordingId);
    }
    output = null;
    youtubeOutput = null;
    questions = null;
    chunkDetails = const [];
    ball = null;
    download = null;
    step = null;
    stepStartedAt = null;
    stepLog = null;
    fraction = null;
    etaS = null;
    chunks = null;
    runElapsedS = null;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await _refresh();
    if (failure != null) _fail(failure);
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
