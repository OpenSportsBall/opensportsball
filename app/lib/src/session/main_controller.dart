// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../link/peer_link.dart';
import '../model.dart';
import '../protocol/messages.dart';
import '../role.dart';
import '../storage/manifest.dart';
import '../storage/store.dart';
import '../upload/account.dart';
import 'local_recorder.dart';

enum MainPhase { starting, idle, preparing, recording, stopping }

/// Whether Secondary uploads to Main's account.
enum SecondaryAccount {
  /// No Secondary yet, or this controller has no [AccountManager].
  unknown,

  /// Main itself is not linked, so it cannot link Secondary.
  mainNotLinked,

  /// A link code was sent; waiting for Secondary's [LinkResult].
  linking,

  /// Same account as Main.
  linked,

  /// Linking failed; see [MainController.secondaryAccountError].
  failed,
}

/// Runs the Main phone: advertises the game, controls Secondary, records,
/// and writes the manifest when it stops. Secondary's segment reports over
/// Bluetooth are for the screen only; Secondary uploads its own list.
class MainController extends ChangeNotifier {
  MainController({
    required this.store,
    required DualCamera camera,
    required PeerLink Function(String gameId) linkFactory,
    this.account,
    String? gameId,
    this.startDelay = const Duration(milliseconds: 1200),
    this.retryEvery = const Duration(seconds: 2),
  })  : gameId = gameId ?? const Uuid().v4(),
        recorder = LocalRecorder(camera: camera, store: store, role: DeviceRole.main) {
    link = linkFactory(this.gameId);
  }

  final AppStore store;
  final String gameId;
  final LocalRecorder recorder;
  late final PeerLink link;

  /// This phone's account. When it is linked, Secondary is linked to the
  /// same account as it pairs, so its footage is accepted with Main's
  /// manifest.
  final AccountManager? account;

  /// How far ahead Start is scheduled, so Secondary gets it in time.
  final Duration startDelay;
  final Duration retryEvery;

  MainPhase phase = MainPhase.starting;
  OpenResult? opened;
  String? error;

  DeviceIdentity? secondary;
  StatusMsg? secondaryStatus;
  DateTime? secondaryStatusAt;
  ClockEstimate? clock;
  DeviceStatus? ownStatus;

  SecondaryAccount secondaryAccount = SecondaryAccount.unknown;
  String? secondaryAccountError;
  DateTime? _linkOfferedAt;

  /// Secondary that already failed to link in this game; reconnects don't
  /// retry, the error stays on screen.
  String? _linkFailedFor;

  /// Recordings made in this game, by id, so late Secondary reports land.
  final recordings = <String, LocalRecording>{};
  final manifestsWritten = <String>{};

  final _waiters = <String, Completer<Msg>>{};
  StreamSubscription<Msg>? _sub;
  Timer? _statusTimer;
  bool _disposed = false;

  LocalRecording? get current => recorder.current;

  bool get secondaryConnected =>
      link.state.value == LinkState.connected && secondary != null;

  /// No heartbeat from Secondary for 6 s.
  bool get secondaryStale =>
      secondaryStatusAt == null ||
      DateTime.now().difference(secondaryStatusAt!) > const Duration(seconds: 6);

  Future<void> init() async {
    _sub = link.messages.listen(_onMsg);
    link.state.addListener(_onLinkState);
    recorder.onReopened = (o) {
      opened = o;
      _notify();
    };
    recorder.onEnded = (rec, reason) {
      error = 'Recording stopped: $reason';
      phase = MainPhase.idle;
      unawaited(_sendUntil(Stop(rec.recordingId), 'stopped', rec.recordingId,
          timeout: const Duration(seconds: 60)));
      _notify();
    };
    // Camera first, and never behind Bluetooth: Bluetooth can wait forever
    // (switched off, permission prompt pending), and Main must still be able
    // to aim and record alone. Sequential also keeps Android from showing
    // two permission prompts at once, which cancels one of them.
    try {
      opened = await recorder.open(store.settings.toCaptureConfig());
      await recorder.camera.setKeepScreenOn(true);
      phase = MainPhase.idle;
    } on Object catch (e) {
      error = '$e';
    }
    _notify();
    unawaited(link.start().catchError((Object e) {
      error = 'Bluetooth: $e';
      _notify();
    }));
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollStatus());
    unawaited(_pollStatus());
    _notify();
  }

  void _onLinkState() {
    if (link.state.value != LinkState.connected) secondary = null;
    _notify();
  }

  Future<void> _pollStatus() async {
    if (opened == null) return;
    try {
      ownStatus = await recorder.camera.status();
      _notify();
    } on Object catch (_) {}
  }

  void _onMsg(Msg m) {
    switch (m) {
      case Hello():
        secondary = m.device;
        unawaited(link.send(Welcome(
          gameId: gameId,
          mainDeviceId: store.identity.deviceId,
          settings: store.settings,
        )));
        unawaited(_checkSecondaryAccount(m));
      case LinkResult():
        _onLinkResult(m);
      case Ping():
        unawaited(link.send(
            Pong(id: m.id, t1: m.t1, t2: DateTime.now().millisecondsSinceEpoch)));
      case ClockReport():
        clock = m.estimate;
        final rec = current;
        if (rec != null && rec.peer != null && !rec.stopped) {
          rec.peer!.clock = m.estimate;
        }
      case Prepared():
        _complete('prepared', m.recordingId, m);
      case Started():
        recordings[m.recordingId]?.peer?.startedAtDeviceMs = m.startedAtDeviceMs;
        _complete('started', m.recordingId, m);
      case Stopped():
        final rec = recordings[m.recordingId];
        rec?.peer?.expectedSegments = m.segmentCount;
        _complete('stopped', m.recordingId, m);
        if (rec != null) unawaited(_maybeFinish(rec));
      case SegmentMsg():
        final rec = recordings[m.recordingId];
        if (rec?.peer != null) {
          rec!.peer!.segments[m.segment.index] = m.segment;
          unawaited(_maybeFinish(rec));
        }
      case StatusMsg():
        secondaryStatus = m;
        secondaryStatusAt = DateTime.now();
      case ErrorMsg():
        error = 'Secondary: ${m.message}';
      case Welcome() || Pong() || Prepare() || Start() || Stop() || LinkOffer():
        break; // Main -> Secondary only.
    }
    _notify();
  }

  String? get _ownAccountId {
    final a = account;
    return a != null && a.linked && !a.revoked ? a.link!.accountId : null;
  }

  /// Links Secondary to this phone's account if it uploads elsewhere (or
  /// nowhere): Main creates a link code and sends it over Bluetooth.
  Future<void> _checkSecondaryAccount(Hello h) async {
    final a = account;
    if (a == null) return;
    final mine = _ownAccountId;
    if (mine == null) {
      secondaryAccount = SecondaryAccount.mainNotLinked;
    } else if (h.accountId == mine) {
      secondaryAccount = SecondaryAccount.linked;
      secondaryAccountError = null;
    } else if (_linkFailedFor == h.device.deviceId) {
      // Keep showing the failure.
    } else if (secondaryAccount == SecondaryAccount.linking &&
        DateTime.now().difference(_linkOfferedAt!) < const Duration(minutes: 1)) {
      // An offer is already on its way.
    } else {
      secondaryAccount = SecondaryAccount.linking;
      secondaryAccountError = null;
      _linkOfferedAt = DateTime.now();
      _notify();
      try {
        final req = await a.createLinkCode();
        if (!await link.send(LinkOffer(apiUrl: req.apiUrl, code: req.code))) {
          secondaryAccount = SecondaryAccount.unknown; // disconnected; the next Hello retries
        }
      } on LinkException catch (e) {
        _linkFailed(h.device.deviceId, e.message);
      }
    }
    _notify();
  }

  void _onLinkResult(LinkResult r) {
    final mine = _ownAccountId;
    if (r.ok && r.accountId != null && r.accountId == mine) {
      secondaryAccount = SecondaryAccount.linked;
      secondaryAccountError = null;
    } else if (secondary != null) {
      _linkFailed(secondary!.deviceId, r.error ?? 'Secondary linked to a different account.');
    }
  }

  void _linkFailed(String deviceId, String message) {
    _linkFailedFor = deviceId;
    secondaryAccount = SecondaryAccount.failed;
    secondaryAccountError = message;
  }

  /// Starts recording on both phones. With [alone] (or no Secondary
  /// connected) only this phone records; returns false if Secondary was
  /// expected but did not get ready.
  Future<bool> startRecording({bool alone = false}) async {
    if (phase != MainPhase.idle) return false;
    error = null;
    phase = MainPhase.preparing;
    _notify();

    final recordingId = const Uuid().v4();
    final withSecondary = !alone && secondaryConnected;
    try {
      Prepared? prepared;
      if (withSecondary) {
        prepared = await _sendUntil(Prepare(recordingId), 'prepared', recordingId,
            timeout: const Duration(seconds: 10)) as Prepared?;
        if (prepared == null || !prepared.ok) {
          error = prepared == null
              ? 'Secondary did not respond.'
              : 'Secondary could not get ready: ${prepared.error}';
          phase = MainPhase.idle;
          _notify();
          return false;
        }
      }
      await recorder.lock();

      final startAt = DateTime.now().add(withSecondary ? startDelay : Duration.zero);
      if (withSecondary) {
        unawaited(_sendUntil(
          Start(recordingId: recordingId, atMainMs: startAt.millisecondsSinceEpoch),
          'started',
          recordingId,
          timeout: const Duration(seconds: 10),
        ).then((ack) {
          if (ack == null) {
            error = 'Secondary did not confirm it started recording.';
            _notify();
          }
        }));
      }
      final wait = startAt.difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);

      final rec = await recorder.start(gameId: gameId, recordingId: recordingId);
      if (withSecondary) {
        rec.peer = PeerRecord(device: secondary!, video: prepared!.video, clock: clock);
      }
      recordings[recordingId] = rec;
      await store.saveRecording(rec);
      phase = MainPhase.recording;
      _notify();
      return true;
    } on Object catch (e) {
      error = '$e';
      phase = MainPhase.idle;
      _notify();
      return false;
    }
  }

  Future<void> stopRecording() async {
    final rec = current;
    if (rec == null || phase != MainPhase.recording) return;
    phase = MainPhase.stopping;
    _notify();
    if (rec.peer != null) {
      // Secondary may be out of range; keep trying for a while. A later
      // reconnect also delivers its segments (it re-sends them on Welcome).
      unawaited(_sendUntil(Stop(rec.recordingId), 'stopped', rec.recordingId,
              timeout: const Duration(seconds: 60))
          .then((ack) {
        if (ack == null) {
          error = 'Secondary has not confirmed it stopped. Check that phone.';
          _notify();
        }
      }));
    }
    try {
      await recorder.stop();
    } on Object catch (e) {
      error = '$e';
    }
    await _maybeFinish(rec);
    phase = MainPhase.idle;
    _notify();
  }

  /// Saves what Secondary reported, and writes the manifest once this phone
  /// has stopped. The manifest does not wait for Secondary: Secondary
  /// uploads its own segment list.
  Future<void> _maybeFinish(LocalRecording rec) async {
    await store.saveRecording(rec);
    if (manifestsWritten.contains(rec.recordingId)) return;
    final manifest = buildManifest(rec);
    if (manifest == null) return;
    manifestsWritten.add(rec.recordingId);
    await store.saveManifest(rec, manifest);
    _notify();
  }

  /// Sends [msg] every [retryEvery] until a [replyType] for [recordingId]
  /// arrives or [timeout] passes. Returns the reply, or null.
  Future<Msg?> _sendUntil(
    Msg msg,
    String replyType,
    String recordingId, {
    required Duration timeout,
  }) async {
    final key = '$replyType:$recordingId';
    final waiter = _waiters.putIfAbsent(key, Completer<Msg>.new);
    final deadline = DateTime.now().add(timeout);
    while (!waiter.isCompleted && DateTime.now().isBefore(deadline) && !_disposed) {
      await link.send(msg);
      await Future.any([waiter.future, Future<void>.delayed(retryEvery)]);
    }
    _waiters.remove(key);
    return waiter.isCompleted ? waiter.future : null;
  }

  void _complete(String type, String recordingId, Msg m) {
    final w = _waiters['$type:$recordingId'];
    if (w != null && !w.isCompleted) w.complete(m);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _statusTimer?.cancel();
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
