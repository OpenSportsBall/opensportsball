// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/foundation.dart';
import 'package:sportsballvideo/src/link/peer_link.dart';
import 'package:sportsballvideo/src/model.dart';
import 'package:sportsballvideo/src/protocol/messages.dart';
import 'package:sportsballvideo/src/storage/store.dart';

/// Two in-memory links wired to each other. Messages go through
/// encode/decode so serialization is exercised too.
class FakeLinkPair {
  FakeLinkPair() {
    main = FakeLink(this);
    secondary = FakeLink(this);
  }
  late final FakeLink main;
  late final FakeLink secondary;

  FakeLink other(FakeLink l) => identical(l, main) ? secondary : main;

  void connect() {
    main._state.value = LinkState.connected;
    secondary._state.value = LinkState.connected;
  }

  void disconnect() {
    main._state.value = LinkState.advertising;
    secondary._state.value = LinkState.searching;
  }
}

class FakeLink implements PeerLink {
  FakeLink(this._pair);
  final FakeLinkPair _pair;
  final _state = ValueNotifier(LinkState.idle);
  final _problem = ValueNotifier<String?>(null);
  final _messages = StreamController<Msg>.broadcast();
  final sent = <Msg>[];

  /// Drop every message of these types (simulates loss).
  final dropTypes = <String>{};

  @override
  ValueListenable<LinkState> get state => _state;
  @override
  ValueListenable<String?> get problem => _problem;
  @override
  Stream<Msg> get messages => _messages.stream;

  /// Completes start(); tests can hold it to simulate Bluetooth that never
  /// becomes ready.
  Completer<void> started = Completer<void>()..complete();

  @override
  Future<void> start() => started.future;

  @override
  Future<bool> send(Msg msg) async {
    if (_state.value != LinkState.connected) return false;
    sent.add(msg);
    if (dropTypes.contains(msg.type)) return true;
    final decoded = Msg.decode(msg.encode());
    final other = _pair.other(this);
    scheduleMicrotask(() {
      if (!other._messages.isClosed) other._messages.add(decoded);
    });
    return true;
  }

  @override
  Future<void> dispose() async => _messages.close();
}

/// A camera that writes small real files so hashing and storage run for
/// real. Call [finishSegment] to simulate a segment rollover.
class FakeCamera implements DualCamera {
  FakeCamera({this.fail = false});
  final bool fail;
  final _events = StreamController<CameraEvent>.broadcast();
  String? _dir;
  String? _prefix;
  int _index = 0;
  int _segmentStart = 0;
  bool recording = false;
  bool locked = false;
  final _rng = Random(1);

  @override
  Stream<CameraEvent> get events => _events.stream;

  @override
  Future<Permissions> checkPermissions() async =>
      const Permissions(camera: true, microphone: true);
  @override
  Future<Permissions> requestPermissions() => checkPermissions();
  @override
  Future<bool> requestBluetoothPermission() async => true;
  @override
  Future<List<Lens>> availableLenses() async => [Lens.ultrawide, Lens.wide];

  @override
  Future<OpenResult> open(CaptureConfig config) async {
    if (fail) throw StateError('camera_unavailable');
    return OpenResult(
      textureId: 1,
      previewWidth: 1280,
      previewHeight: 720,
      width: config.width,
      height: config.height,
      fps: config.fps,
      codec: config.codec,
      lens: config.lens,
      horizontalFovDeg: 108.5,
    );
  }

  @override
  Future<LockResult> lockSettings() async {
    locked = true;
    return const LockResult(exposureLocked: false, whiteBalanceLocked: true, focusLocked: true);
  }

  @override
  Future<int> startRecording({required String directory, required String filePrefix}) async {
    _dir = directory;
    _prefix = filePrefix;
    _index = 0;
    recording = true;
    _segmentStart = DateTime.now().millisecondsSinceEpoch;
    return _segmentStart;
  }

  Future<void> finishSegment() async {
    final path = '$_dir/${_prefix}_${_index.toString().padLeft(3, '0')}.mp4';
    final bytes = List.generate(4096 + _index, (_) => _rng.nextInt(256));
    await File(path).writeAsBytes(bytes);
    final now = DateTime.now().millisecondsSinceEpoch;
    _events.add(SegmentEvent(
      index: _index,
      path: path,
      bytes: bytes.length,
      startedAtDeviceMs: _segmentStart,
      duration: Duration(milliseconds: now - _segmentStart),
    ));
    _index++;
    _segmentStart = now;
  }

  void interrupt() {
    recording = false;
    _events.add(const InterruptedEvent('phone call'));
  }

  @override
  Future<void> stopRecording() async {
    if (!recording) return;
    await finishSegment();
    recording = false;
  }

  @override
  Future<DeviceStatus> status() async => DeviceStatus(
        batteryPercent: 80,
        charging: false,
        freeStorageBytes: 50 * 1024 * 1024 * 1024,
        thermalState: ThermalState.nominal,
        recording: recording,
      );

  @override
  Future<void> setKeepScreenOn(bool on) async {}

  /// Every brightness override requested; null means "back to the system".
  final brightness = <double?>[];
  bool previewPaused = false;

  @override
  Future<void> setScreenBrightness(double? level) async => brightness.add(level);
  @override
  Future<void> setPreviewPaused(bool paused) async => previewPaused = paused;
  @override
  Future<void> close() async {}
}

Future<AppStore> tempStore(String name, {String platform = 'ios'}) async {
  final dir = await Directory.systemTemp.createTemp('sbv_$name');
  final root = Directory('${dir.path}/recordings')..createSync();
  return AppStore.forTest(
    supportDir: dir,
    recordingsRoot: root,
    identity: DeviceIdentity(
      deviceId: '${name}0000-0000-4000-8000-000000000000'.substring(0, 36),
      platform: platform,
      model: '$name-model',
    ),
    settings: const RecordingSettings(segmentMinutes: 1),
  );
}

/// Polls [condition] until true or [timeout].
Future<void> eventually(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10), String? reason}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('condition not met: ${reason ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
