// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opensportsball/src/link/peer_link.dart';
import 'package:opensportsball/src/session/main_controller.dart';
import 'package:opensportsball/src/session/secondary_controller.dart';
import 'package:opensportsball/src/storage/store.dart';

import 'fakes.dart';

/// Main and Secondary controllers talking over an in-memory link, with fake
/// cameras writing real files.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // for AppLifecycleListener
  late FakeLinkPair links;
  late FakeCamera mainCam, secCam;
  late AppStore mainStore, secStore;
  late MainController main;
  late SecondaryController sec;

  setUp(() async {
    links = FakeLinkPair();
    mainCam = FakeCamera();
    secCam = FakeCamera();
    mainStore = await tempStore('aaaaaaaa');
    secStore = await tempStore('bbbbbbbb', platform: 'android');
    final server = FakeGrantServer();
    main = MainController(
      store: mainStore,
      camera: mainCam,
      linkFactory: (_) => links.main,
      account: await fakeAccount(mainStore, server.client, accountId: 'acc-main'),
      startDelay: const Duration(milliseconds: 50),
      retryEvery: const Duration(milliseconds: 100),
    );
    sec = SecondaryController(
      store: secStore,
      camera: secCam,
      gameId: main.gameId,
      linkFactory: (_) => links.secondary,
      account: await fakeAccount(secStore, server.client),
      pingsPerRound: 5,
      pingSpacing: const Duration(milliseconds: 1),
    );
    main.recorder.settlePollEvery = const Duration(milliseconds: 5);
    sec.recorder.settlePollEvery = const Duration(milliseconds: 5);
    await main.init();
    await sec.init();
  });

  tearDown(() async {
    await main.dispose();
    await sec.dispose();
  });

  Future<void> pair() async {
    links.connect();
    await eventually(() => sec.phase == SecondaryPhase.ready, reason: 'secondary ready');
    await eventually(() => main.clock != null, reason: 'clock estimate');
    await eventually(() => main.grantState == GrantState.delivered, reason: 'grant');
  }

  test('Main opens its camera even if Bluetooth never becomes ready', () async {
    final stuck = FakeLinkPair();
    stuck.main.started = Completer<void>(); // e.g. Bluetooth off
    final m = MainController(store: mainStore, camera: FakeCamera(), linkFactory: (_) => stuck.main);
    await m.init().timeout(const Duration(seconds: 2));
    expect(m.opened, isNotNull);
    expect(m.phase, MainPhase.idle);
    expect(await m.startRecording(alone: true), isTrue);
    await m.stopRecording();
    await m.dispose();
  });

  test('Main fails cleanly when its camera will not open, and can retry', () async {
    final cam = FakeCamera(fail: true);
    final m = MainController(store: mainStore, camera: cam, linkFactory: (_) => FakeLinkPair().main);
    await m.init();
    expect(m.phase, MainPhase.noCamera);
    expect(m.opened, isNull);
    expect(m.error, "This phone's camera could not be opened."); // not the raw exception
    expect(await m.startRecording(alone: true), isFalse);

    cam.fail = false;
    await m.retryCamera();
    expect(m.phase, MainPhase.idle);
    expect(m.error, isNull);
    expect(m.opened, isNotNull);
    await m.dispose();
  });

  test('Secondary fails cleanly when its camera will not open, and can retry', () async {
    secCam.fail = true;
    links.connect();
    await eventually(() => sec.phase == SecondaryPhase.noCamera, reason: 'secondary has no camera');
    expect(sec.error, "This phone's camera could not be opened.");
    await eventually(() => main.error == 'Secondary: could not open its camera',
        reason: 'main hears about it');

    secCam.fail = false;
    await sec.retryCamera();
    expect(sec.phase, SecondaryPhase.ready);
    expect(sec.error, isNull);
  });

  test('pairing opens the Secondary camera with Main settings', () async {
    await pair();
    expect(main.secondary!.model, 'bbbbbbbb-model');
    expect(sec.welcome!.settings.segmentMinutes, 1);
    expect(sec.clock!.secondaryOffsetMs.abs(), lessThan(50));
  });

  test('full recording writes a manifest that lists both phones', () async {
    secCam.up = const UpVector(0, -0.985, 0.174); // mounted upside down
    await pair();
    expect(await main.startRecording(), isTrue);
    await eventually(() => secCam.recording, reason: 'secondary recording');
    // Not locked when recording starts: once each phone has sat still on
    // its mount for a few motion windows.
    await eventually(() => mainCam.locked && secCam.locked, reason: 'settings locked once settled');
    expect(mainCam.lastSweepFocus, isTrue);
    // Read while the preview was open, so the files play upright.
    expect(mainCam.lastUprightRotationDeg, 0);
    expect(secCam.lastUprightRotationDeg, 180);

    await mainCam.finishSegment();
    await secCam.finishSegment();
    await main.stopRecording();

    final id = main.current!.recordingId;
    await eventually(() => main.manifestsWritten.contains(id), reason: 'manifest');
    final dir = mainStore.recordingDir(main.gameId, id);
    final manifest = jsonDecode(File('${dir.path}/manifest.json').readAsStringSync()) as Map;

    expect(manifest['gameId'], main.gameId);
    expect(manifest['sessionId'], id);
    expect(manifest['sport'], 'soccer');
    final devices = manifest['devices'] as List;
    expect(devices.map((d) => d['role']), ['main', 'secondary']);
    expect(devices[1]['platform'], 'android');
    expect((manifest['clockSync'] as Map)['samples'], greaterThan(0));
    // Secondary's segments come from Secondary's own report, not Main.
    expect((devices[1] as Map).containsKey('segments'), isFalse);
    await eventually(() => sec.recordings[id]?.stopped ?? false, reason: 'secondary stopped');
    final [stored] = await secStore.listRecordings();
    expect(await secStore.ensureUploadDocument(stored), isTrue);
    final report = jsonDecode(File('${stored.dir.path}/report.json').readAsStringSync()) as Map;
    for (final d in [devices[0] as Map, report]) {
      final segs = d['segments'] as List;
      expect(segs.length, 2);
      expect(segs.map((s) => s['index']), [0, 1]);
      expect(segs.every((s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s['sha256'] as String)), isTrue);
      expect(segs.first['objectKey'], '${d['deviceId']}/${d['deviceId']}_000.mp4');
    }
    expect(report['deviceId'], devices[1]['deviceId']);
    // Each phone measures which way up it is; Secondary's comes in its report.
    expect(devices[0]['orientation'], {'uprightRotationDeg': 0, 'rollDeg': 0.0, 'pitchDeg': -10.0});
    expect((devices[1] as Map).containsKey('orientation'), isFalse);
    expect(report['orientation'], {'uprightRotationDeg': 180, 'rollDeg': 0.0, 'pitchDeg': -10.0});
    for (final d in [devices[0] as Map, report]) {
      final [lock] = d['settingsLocks'] as List;
      expect(lock['reason'], 'settled');
      expect(lock['focus'], {'method': 'infinity'});
      expect(lock['orientation'], d['orientation']);
      expect(lock['atDeviceMs'], greaterThan((d['segments'] as List).first['startedAtDeviceMs'] as int));
    }

    final out = Platform.environment['OSB_MANIFEST_OUT'];
    if (out != null) File(out).writeAsStringSync(jsonEncode(manifest));
  });

  test('Secondary keeps recording through a dropped link and reports on reconnect', () async {
    await pair();
    await main.startRecording();
    await eventually(() => secCam.recording);

    links.disconnect();
    await secCam.finishSegment();
    await mainCam.finishSegment();
    // Main stops while Secondary is out of range: Stop retries go nowhere.
    await main.stopRecording();
    expect(secCam.recording, isTrue, reason: 'secondary must not stop on link loss');

    // Main's manifest does not wait for Secondary.
    final id = main.current!.recordingId;
    await eventually(() => main.manifestsWritten.contains(id), reason: 'manifest while apart');

    // Secondary is stopped by hand; its report needs nothing from Main.
    await sec.stopLocally();
    final [stored] = await secStore.listRecordings();
    expect(await secStore.ensureUploadDocument(stored), isTrue);

    // Back in range, the screen catches up too.
    links.connect();
    await eventually(() => main.current!.peer!.segments.length == 2, reason: 'reports after reconnect');
  });

  test('Secondary ignores duplicate Start and Stop retries', () async {
    await pair();
    links.secondary.dropTypes.add('started'); // Main keeps retrying Start
    await main.startRecording();
    await eventually(() => secCam.recording);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(sec.recordings.length, 1);
    links.secondary.dropTypes.clear();

    await main.stopRecording();
    final id = main.current!.recordingId;
    await eventually(() => main.manifestsWritten.contains(id));
    expect(sec.recordings[id]!.segments.length, 1);
  });

  test('Main can record alone when no Secondary is connected', () async {
    expect(main.secondaryConnected, isFalse);
    expect(await main.startRecording(alone: true), isTrue);
    await main.stopRecording();
    final rec = main.current!;
    expect(rec.peer, isNull);
    expect(rec.segments.length, 1);
    await eventually(() => main.manifestsWritten.contains(rec.recordingId));
    final dir = mainStore.recordingDir(main.gameId, rec.recordingId);
    final manifest = jsonDecode(File('${dir.path}/manifest.json').readAsStringSync()) as Map;
    expect((manifest['devices'] as List).length, 1);
    expect(manifest.containsKey('clockSync'), isFalse);
    final power = File('${dir.path}/power.csv').readAsLinesSync();
    expect(power.first, startsWith('elapsed_s,'));
    expect(power.skip(1).map((l) => l.split(',').last), ['start', 'stop']);
    final out = Platform.environment['OSB_SOLO_MANIFEST_OUT'];
    if (out != null) File(out).writeAsStringSync(jsonEncode(manifest));
  });

  test('an interruption ends the recording and tells Main', () async {
    await pair();
    await main.startRecording();
    await eventually(() => secCam.recording);
    await secCam.finishSegment();
    secCam.interrupt();
    await eventually(() => main.error != null, reason: 'main hears about it');
    expect(main.error, contains('phone call'));
    expect(sec.current!.endReason, contains('phone call'));
  });

  test('the camera reopens after an interruption', () async {
    await pair();
    final before = sec.opened;
    secCam.interrupt();
    await eventually(() => !identical(sec.opened, before),
        timeout: const Duration(seconds: 5), reason: 'reopened');
    expect(sec.phase, SecondaryPhase.ready);
  });

  test('a recording the app died during is recovered at startup', () async {
    // A dead app runs no timers. The live recorder would otherwise lock
    // focus mid-test and save its own copy of the recording (still
    // recording) over the recovered one.
    main.recorder.settlePollEvery = const Duration(days: 1);
    expect(await main.startRecording(alone: true), isTrue);
    await mainCam.finishSegment(); // hashed and recorded
    final rec = main.current!;
    final dir = mainStore.recordingDir(main.gameId, rec.recordingId);
    // A segment that reached disk but was never hashed, and an empty
    // pre-created next file (iOS), then the app dies.
    final orphan = File('${dir.path}/${mainStore.identity.deviceId}_001.mp4')
      ..writeAsBytesSync(List.filled(5000, 7));
    File('${dir.path}/${mainStore.identity.deviceId}_002.mp4').writeAsBytesSync([]);

    expect(await mainStore.recoverInterruptedRecordings(), 1);
    final [stored] = await mainStore.listRecordings();
    expect(stored.recording.stopped, isTrue);
    expect(stored.recording.endReason, 'app closed while recording');
    expect(stored.recording.segments.map((s) => s.fileName),
        ['${mainStore.identity.deviceId}_000.mp4', orphan.uri.pathSegments.last]);
    expect(stored.recording.segments[1].bytes, 5000);
    expect(await mainStore.recoverInterruptedRecordings(), 0);
  });

  test('link state drives the Secondary phase', () async {
    expect(sec.phase, SecondaryPhase.connecting);
    links.connect();
    await eventually(() => sec.phase == SecondaryPhase.ready);
    links.disconnect();
    expect(links.secondary.state.value, LinkState.searching);
    expect(sec.phase, SecondaryPhase.connecting);
  });
}
