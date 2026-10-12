// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/foundation.dart';

import '../link/peer_link.dart';
import '../model.dart';
import '../protocol/clock_sync.dart';
import '../protocol/messages.dart';
import '../role.dart';
import '../storage/store.dart';
import '../upload/account.dart';
import 'local_recorder.dart';

enum SecondaryPhase { connecting, waitingForMain, ready, recording, stopping }

/// Runs the Secondary phone: connects to Main, follows its commands, keeps
/// recording if the link drops, and reports segments back.
class SecondaryController extends ChangeNotifier {
  SecondaryController({
    required this.store,
    required DualCamera camera,
    required this.gameId,
    required PeerLink Function(String gameId) linkFactory,
    this.account,
    this.pingsPerRound = 20,
    this.pingSpacing = const Duration(milliseconds: 150),
  }) : recorder = LocalRecorder(camera: camera, store: store, role: DeviceRole.secondary) {
    link = linkFactory(gameId);
  }

  final AppStore store;
  final String gameId;
  final LocalRecorder recorder;
  late final PeerLink link;

  /// Keeps the recording grant Main sends ([GrantMsg]), so this phone's
  /// footage uploads into Main's account whatever account it is on.
  final AccountManager? account;
  final int pingsPerRound;
  final Duration pingSpacing;

  Welcome? welcome;
  OpenResult? opened;
  ClockEstimate? clock;
  String? error;
  bool _stopping = false;

  /// Main's recording grant for this game, once it arrives (or from an
  /// earlier session of the same game).
  RecordingGrant? grant;
  String? grantError;

  final recordings = <String, LocalRecording>{};
  final _samples = <ClockSample>[];
  final _pingsSent = <int, int>{};
  int _nextPingId = 0;
  String? _scheduledStart;

  StreamSubscription<Msg>? _sub;
  Timer? _statusTimer;
  Timer? _clockTimer;
  bool _disposed = false;

  LocalRecording? get current => recorder.current;

  SecondaryPhase get phase {
    if (_stopping) return SecondaryPhase.stopping;
    if (recorder.recording) return SecondaryPhase.recording;
    if (link.state.value != LinkState.connected) return SecondaryPhase.connecting;
    if (welcome == null || opened == null) return SecondaryPhase.waitingForMain;
    return SecondaryPhase.ready;
  }

  bool get connected => link.state.value == LinkState.connected;

  Future<void> init() async {
    _sub = link.messages.listen(_onMsg);
    link.state.addListener(_onLinkState);
    recorder.onSegment = (rec, seg) =>
        unawaited(link.send(SegmentMsg(recordingId: rec.recordingId, segment: seg)));
    recorder.onReopened = (o) {
      opened = o;
      _notify();
    };
    recorder.onEnded = (rec, reason) {
      error = 'Recording stopped: $reason';
      unawaited(link.send(ErrorMsg(code: 'recording_ended', message: reason)));
      _notify();
    };
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sendStatus());
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (connected) unawaited(_clockRound());
    });
    try {
      await recorder.camera.setKeepScreenOn(true);
    } on Object catch (_) {}
    grant = await account?.grantFor(gameId);
    await link.start();
    _notify();
  }

  void _onLinkState() {
    if (connected) {
      unawaited(link.send(Hello(store.identity)));
    }
    _notify();
  }

  Future<void> _onMsg(Msg m) async {
    switch (m) {
      case Welcome():
        await _onWelcome(m);
      case Pong():
        final sent = _pingsSent.remove(m.id);
        if (sent != null) {
          _samples.add(ClockSample(t1: m.t1, t2: m.t2, t3: DateTime.now().millisecondsSinceEpoch));
          if (_samples.length > 200) _samples.removeAt(0);
        }
      case Prepare():
        await _onPrepare(m);
      case Start():
        await _onStart(m);
      case Stop():
        await _onStop(m.recordingId);
      case GrantMsg():
        await _onGrant(m.grant);
      case Hello() || Ping() || ClockReport() || Prepared() || Started() ||
            Stopped() || SegmentMsg() || StatusMsg() || ErrorMsg() || GrantAck():
        break; // Secondary -> Main only.
    }
    _notify();
  }

  /// Keeps Main's grant for this game. It does not change which account
  /// this phone is linked to.
  Future<void> _onGrant(RecordingGrant g) async {
    final a = account;
    String? problem;
    if (a == null) {
      problem = 'This screen cannot keep upload permission.';
    } else if (g.gameId != gameId) {
      problem = 'Upload permission was for another game.';
    } else if (!isAcceptableApiUrl(g.apiUrl)) {
      problem = 'Upload permission points to an address that is not HTTPS.';
    } else {
      try {
        await a.saveGrant(g);
        grant = g;
      } on Object catch (e) {
        problem = 'Could not save upload permission: $e';
      }
    }
    grantError = problem;
    await link.send(GrantAck(gameId: g.gameId, error: problem));
  }

  Future<void> _onWelcome(Welcome m) async {
    if (m.gameId != gameId) return;
    final settingsChanged =
        welcome == null || !mapEquals(welcome!.settings.toJson(), m.settings.toJson());
    welcome = m;
    if ((opened == null || settingsChanged) && !recorder.recording) {
      try {
        opened = await recorder.open(m.settings.toCaptureConfig());
        error = null;
      } on Object catch (e) {
        error = '$e';
        await link.send(ErrorMsg(code: 'camera', message: '$e'));
      }
    }
    unawaited(_clockRound());
    await _resendStoppedRecordings();
  }

  /// After a reconnect, Main may have missed segments or the stopped
  /// confirmation. Re-sending is safe: Main de-duplicates.
  Future<void> _resendStoppedRecordings() async {
    for (final rec in recordings.values) {
      for (final seg in rec.segments) {
        await link.send(SegmentMsg(recordingId: rec.recordingId, segment: seg));
      }
      if (rec.stopped) {
        await link.send(Stopped(recordingId: rec.recordingId, segmentCount: rec.segments.length));
      }
    }
  }

  Future<void> _onPrepare(Prepare m) async {
    final o = opened, c = recorder.config;
    if (o == null || c == null) {
      await link.send(Prepared(recordingId: m.recordingId, error: error ?? 'camera is not open'));
      return;
    }
    try {
      if (!recorder.recording) await recorder.lock();
      await link.send(Prepared(recordingId: m.recordingId, video: VideoInfo.fromOpen(o, c)));
    } on Object catch (e) {
      await link.send(Prepared(recordingId: m.recordingId, error: '$e'));
    }
  }

  Future<void> _onStart(Start m) async {
    final rec = current;
    if (rec != null && rec.recordingId == m.recordingId) {
      // Duplicate (Main retries until acknowledged).
      await link.send(Started(recordingId: rec.recordingId, startedAtDeviceMs: rec.startedAtDeviceMs ?? 0));
      return;
    }
    if (_scheduledStart == m.recordingId || recorder.recording) return;
    _scheduledStart = m.recordingId;

    // Convert Main's clock to ours; start late rather than never.
    final offset = clock?.secondaryOffsetMs ?? 0;
    final localTarget = m.atMainMs + offset.round();
    final wait = localTarget - DateTime.now().millisecondsSinceEpoch;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait.clamp(0, 5000)));

    try {
      final started = await recorder.start(gameId: gameId, recordingId: m.recordingId);
      recordings[started.recordingId] = started;
      await link.send(Started(
        recordingId: started.recordingId,
        startedAtDeviceMs: started.startedAtDeviceMs ?? 0,
      ));
    } on Object catch (e) {
      error = '$e';
      await link.send(ErrorMsg(code: 'start_failed', message: '$e'));
    } finally {
      _scheduledStart = null;
      _notify();
    }
  }

  Future<void> _onStop(String recordingId) async {
    final rec = recordings[recordingId];
    if (rec == null) {
      // Never started (e.g. Start was lost). Nothing to wait for.
      await link.send(Stopped(recordingId: recordingId, segmentCount: 0));
      return;
    }
    if (_stopping) return; // A retry while the first Stop is in progress.
    if (!rec.stopped) await _stopLocal();
    for (final seg in rec.segments) {
      await link.send(SegmentMsg(recordingId: rec.recordingId, segment: seg));
    }
    await link.send(Stopped(recordingId: rec.recordingId, segmentCount: rec.segments.length));
  }

  /// Stops recording from this phone, e.g. when Main is out of range.
  Future<void> stopLocally() async {
    final rec = current;
    if (rec == null || rec.stopped) return;
    await _stopLocal();
    if (connected) await _onStop(rec.recordingId);
  }

  Future<void> _stopLocal() async {
    _stopping = true;
    _notify();
    try {
      await recorder.stop();
    } on Object catch (e) {
      error = '$e';
    } finally {
      _stopping = false;
      _notify();
    }
  }

  Future<void> _clockRound() async {
    for (var i = 0; i < pingsPerRound && connected && !_disposed; i++) {
      final id = _nextPingId++;
      final t1 = DateTime.now().millisecondsSinceEpoch;
      _pingsSent[id] = t1;
      await link.send(Ping(id: id, t1: t1));
      await Future<void>.delayed(pingSpacing);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _pingsSent.clear();
    final estimate = estimateClock(_samples);
    if (estimate == null || _disposed) return;
    clock = estimate;
    await link.send(ClockReport(estimate));
    _notify();
  }

  Future<void> _sendStatus() async {
    if (!connected || opened == null) return;
    try {
      final s = await recorder.camera.status();
      final rec = current;
      final recording = rec != null && !rec.stopped;
      await link.send(StatusMsg(
        batteryPercent: s.batteryPercent,
        charging: s.charging,
        freeStorageBytes: s.freeStorageBytes,
        thermalState: s.thermalState.name,
        recordingId: recording ? rec.recordingId : null,
        segmentCount: rec?.segments.length ?? 0,
        elapsedMs: recording && rec.startedAtDeviceMs != null
            ? DateTime.now().millisecondsSinceEpoch - rec.startedAtDeviceMs!
            : 0,
      ));
    } on Object catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _statusTimer?.cancel();
    _clockTimer?.cancel();
    link.state.removeListener(_onLinkState);
    await _sub?.cancel();
    try {
      await recorder.camera.setKeepScreenOn(false);
      await recorder.close();
    } on Object catch (_) {}
    await link.dispose();
    super.dispose();
  }
}
