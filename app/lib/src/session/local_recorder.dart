// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/widgets.dart';

import '../model.dart';
import '../role.dart';
import '../storage/store.dart';
import 'activity.dart';
import 'power_log.dart';

/// Drives this phone's camera for one game: opens it, records, and turns
/// each finished segment file into a hashed [SegmentRecord] saved in
/// `recording.json`. Used by both the Main and Secondary controllers.
class LocalRecorder {
  LocalRecorder({
    required this.camera,
    required this.store,
    required this.role,
    DeviceActivity? activity,
    this.powerLogEvery = const Duration(minutes: 1),
  }) : activity = activity ?? DeviceActivity.instance;

  final DualCamera camera;
  final AppStore store;
  final DeviceRole role;

  /// Told when recording starts and ends, so uploads pause meanwhile.
  final DeviceActivity activity;

  /// How often `power.csv` gets a battery / thermal row while recording.
  final Duration powerLogEvery;

  OpenResult? opened;
  CaptureConfig? config;
  LocalRecording? current;

  /// Called after each segment is hashed and saved.
  void Function(LocalRecording rec, SegmentRecord seg)? onSegment;

  /// Called when recording ends without [stop]: a fatal error or the OS
  /// taking the camera away.
  void Function(LocalRecording rec, String reason)? onEnded;

  /// Called when the camera was reopened after an interruption (the
  /// preview texture changes).
  void Function(OpenResult opened)? onReopened;

  final _hashing = <Future<void>>[];
  bool _needsReopen = false;
  bool _reopening = false;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<CameraEvent>? _events;
  Future<void>? _stopping;
  PowerLog? _power;

  bool get recording => current != null && !current!.stopped;

  Future<OpenResult> open(CaptureConfig c) async {
    var perms = await camera.checkPermissions();
    if (!perms.all) perms = await camera.requestPermissions();
    if (!perms.all) {
      throw const RecorderException(
          'Camera and microphone access are both needed. Allow them in Settings.');
    }
    if (opened != null) await camera.close();
    activity.setCameraOpen(this, true);
    _events ??= camera.events.listen(_onEvent);
    opened = await camera.open(c);
    config = c;
    _lifecycle ??= AppLifecycleListener(onResume: () {
      if (_needsReopen) unawaited(_reopen());
    });
    return opened!;
  }

  /// After an interruption the OS may have released the camera (Android
  /// always does). Retry a few times, and again when the app resumes.
  Future<void> _reopen() async {
    final c = config;
    if (_reopening || c == null) return;
    _reopening = true;
    try {
      for (var attempt = 0; attempt < 5 && _needsReopen; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          await camera.close();
          opened = await camera.open(c);
          _needsReopen = false;
          onReopened?.call(opened!);
        } on Object catch (e) {
          debugPrint('camera reopen failed: $e');
        }
      }
    } finally {
      _reopening = false;
    }
  }

  Future<LockResult> lock() => camera.lockSettings();

  Future<LocalRecording> start({
    required String gameId,
    required String recordingId,
  }) async {
    final o = opened, c = config;
    if (o == null || c == null) throw const RecorderException('Camera is not open.');
    if (recording) throw const RecorderException('Already recording.');
    final rec = LocalRecording(
      recordingId: recordingId,
      gameId: gameId,
      role: role,
      device: store.identity,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      video: VideoInfo.fromOpen(o, c),
    );
    final dir = store.recordingDir(gameId, recordingId);
    await dir.create(recursive: true);
    current = rec;
    activity.setRecording(this, true);
    try {
      rec.startedAtDeviceMs = await camera.startRecording(
        directory: dir.path,
        filePrefix: store.identity.deviceId,
      );
    } on Object {
      current = null;
      activity.setRecording(this, false);
      rethrow;
    }
    _power = PowerLog(camera, File('${dir.path}/power.csv'), every: powerLogEvery)..start();
    // Read once recording runs: the phone is on the mount by now.
    try {
      final up = await camera.orientation();
      if (up != null) rec.orientation = MountOrientation.fromUp(up);
    } on Object catch (e) {
      debugPrint('orientation: $e');
    }
    await store.saveRecording(rec);
    return rec;
  }

  /// Stops recording and waits until every segment is hashed and saved.
  Future<LocalRecording?> stop() {
    final rec = current;
    if (rec == null || rec.stopped) return Future.value(rec);
    return (_stopping ??= () async {
      try {
        await camera.stopRecording();
      } finally {
        await _finish(rec, null);
        _stopping = null;
      }
    }())
        .then((_) => rec);
  }

  Future<void> _finish(LocalRecording rec, String? reason) async {
    final power = _power;
    _power = null;
    await power?.stop(reason ?? 'stop');
    await Future.wait(List.of(_hashing));
    rec.stoppedAtMs ??= DateTime.now().millisecondsSinceEpoch;
    rec.endReason ??= reason;
    await store.saveRecording(rec);
    activity.setRecording(this, false);
  }

  void _onEvent(CameraEvent e) {
    if (e is InterruptedEvent && config != null) {
      _needsReopen = true;
      unawaited(_reopen());
    }
    final rec = current;
    if (rec == null) return;
    switch (e) {
      case SegmentEvent():
        late final Future<void> f;
        f = _hashSegment(rec, e).whenComplete(() => _hashing.remove(f));
        _hashing.add(f);
      case CameraErrorEvent(fatal: true):
        unawaited(_endedUnexpectedly(rec, '${e.code}: ${e.message}'));
      case InterruptedEvent():
        unawaited(_endedUnexpectedly(rec, 'interrupted: ${e.reason}'));
      case CameraErrorEvent():
        break;
    }
  }

  Future<void> _endedUnexpectedly(LocalRecording rec, String reason) async {
    if (rec.stopped || _stopping != null) return;
    await _finish(rec, reason);
    onEnded?.call(rec, reason);
  }

  Future<void> _hashSegment(LocalRecording rec, SegmentEvent e) async {
    final path = e.path;
    final digest = await Isolate.run(() => _sha256File(path));
    final seg = SegmentRecord(
      index: e.index,
      fileName: path.split(Platform.pathSeparator).last,
      bytes: e.bytes,
      sha256: digest,
      startedAtDeviceMs: e.startedAtDeviceMs,
      durationMs: e.duration.inMilliseconds,
    );
    rec.segments
      ..removeWhere((s) => s.index == seg.index)
      ..add(seg)
      ..sort((a, b) => a.index.compareTo(b.index));
    await store.saveRecording(rec);
    onSegment?.call(rec, seg);
  }

  Future<void> close() async {
    _needsReopen = false;
    _lifecycle?.dispose();
    _lifecycle = null;
    try {
      if (recording) await stop();
      await _events?.cancel();
      _events = null;
      if (opened != null) {
        opened = null;
        await camera.close();
      }
    } finally {
      activity
        ..setRecording(this, false)
        ..setCameraOpen(this, false);
    }
  }
}

Future<String> _sha256File(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

class RecorderException implements Exception {
  const RecorderException(this.message);
  final String message;
  @override
  String toString() => message;
}
