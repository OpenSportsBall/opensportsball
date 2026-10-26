// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opensportsball/src/link/peer_link.dart';
import 'package:opensportsball/src/model.dart';
import 'package:opensportsball/src/protocol/messages.dart';
import 'package:opensportsball/src/storage/store.dart';
import 'package:opensportsball/src/upload/account.dart';

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

  /// Makes [open] throw, like a camera another app holds.
  bool fail;
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

  /// The `uprightRotationDeg` the last [startRecording] was given.
  int? lastUprightRotationDeg;

  @override
  Future<int> startRecording({
    required String directory,
    required String filePrefix,
    int uprightRotationDeg = 0,
  }) async {
    lastUprightRotationDeg = uprightRotationDeg;
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

  /// What [orientation] answers: upright, looking 10 degrees down.
  UpVector? up = const UpVector(0, 0.985, 0.174);

  @override
  Future<UpVector?> orientation() async => up;

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
  final dir = await Directory.systemTemp.createTemp('osb_$name');
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

/// `POST /games/{gameId}/grants` as the server answers it (docs/API.md),
/// for the device token `osbd_<accountId>`. [log] lists the calls; set
/// [offline] to fail them as if there were no internet.
class FakeGrantServer {
  final log = <String>[];
  bool offline = false;
  var _next = 0;

  /// Tickets issued by `POST /grant-tickets`, and their bindings from
  /// `POST /grants/redeem`: ticket -> (gameId, deviceId).
  final tickets = <String>[];
  final redeemed = <String, (String, String)>{};

  /// Refuse every redemption with 409.
  bool refuseRedeem = false;

  late final http.Client client = MockClient((req) async {
    log.add('${req.method} ${req.url.path}');
    if (offline) throw http.ClientException('no internet');
    final auth = req.headers['Authorization'] ?? '';
    String expires(int days) => DateTime.now().toUtc().add(Duration(days: days)).toIso8601String();
    if (req.method == 'POST' && req.url.path == '/grant-tickets') {
      if (!auth.startsWith('Bearer osbd_')) return http.Response('{}', 401);
      final fresh = [
        for (var i = 0; i < ((jsonDecode(req.body) as Map)['count'] as int); i++) 'osbg_t${tickets.length + i}',
      ];
      tickets.addAll(fresh);
      return http.Response(
          jsonEncode({
            'tickets': [for (final t in fresh) {'ticket': t, 'expiresAt': expires(90)}],
            'apiUrl': 'https://api.test',
            'accountId': auth.substring('Bearer osbd_'.length),
            'open': tickets.length - redeemed.length,
          }),
          201);
    }
    if (req.method == 'POST' && req.url.path == '/grants/redeem') {
      final b = (jsonDecode(req.body) as Map).cast<String, Object?>();
      final ticket = b['ticket'] as String, binding = (b['gameId'] as String, b['deviceId'] as String);
      if (!tickets.contains(ticket)) return http.Response('{"error":"not_found","message":"no ticket"}', 404);
      final bound = redeemed[ticket];
      if (refuseRedeem || (bound != null && bound != binding)) {
        return http.Response('{"error":"conflict","message":"in use"}', 409);
      }
      redeemed[ticket] = binding;
      return http.Response(
          jsonEncode({
            'grantToken': ticket,
            'apiUrl': 'https://api.test',
            'accountId': 'acc-main',
            'gameId': binding.$1,
            'deviceId': binding.$2,
            'expiresAt': expires(14),
          }),
          200);
    }
    final m = RegExp(r'^/games/([^/]+)/grants$').firstMatch(req.url.path);
    if (req.method != 'POST' || m == null) return http.Response('{}', 404);
    if (!auth.startsWith('Bearer osbd_')) return http.Response('{}', 401);
    final body = jsonDecode(req.body) as Map;
    return http.Response(
        jsonEncode({
          'grantToken': 'osbg_${_next++}',
          'apiUrl': 'https://api.test',
          'accountId': auth.substring('Bearer osbd_'.length),
          'gameId': m[1],
          'deviceId': body['deviceId'],
          'expiresAt': DateTime.now().toUtc().add(const Duration(days: 14)).toIso8601String(),
        }),
        201);
  });
}

/// An [AccountManager] on [store], linked to [accountId] (token
/// `osbd_<accountId>`) unless that is null.
Future<AccountManager> fakeAccount(AppStore store, http.Client client, {String? accountId}) async {
  final secrets = MemorySecretStore();
  if (accountId != null) {
    secrets.values['account_link'] = jsonEncode(
        AccountLink(apiUrl: 'https://api.test', deviceToken: 'osbd_$accountId', accountId: accountId).toJson());
  }
  final a = AccountManager(store: store, secrets: secrets, client: client);
  await a.load();
  return a;
}
