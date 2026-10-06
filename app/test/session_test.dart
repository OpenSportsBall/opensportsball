// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sportsballvideo/src/link/peer_link.dart';
import 'package:sportsballvideo/src/session/main_controller.dart';
import 'package:sportsballvideo/src/session/secondary_controller.dart';
import 'package:sportsballvideo/src/storage/store.dart';

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
    main = MainController(
      store: mainStore,
      camera: mainCam,
      linkFactory: (_) => links.main,
      startDelay: const Duration(milliseconds: 50),
      retryEvery: const Duration(milliseconds: 100),
    );
    sec = SecondaryController(
      store: secStore,
      camera: secCam,
      gameId: main.gameId,
      linkFactory: (_) => links.secondary,
      pingsPerRound: 5,
      pingSpacing: const Duration(milliseconds: 1),
    );
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
  }

  test('pairing opens the Secondary camera with Main settings', () async {
    await pair();
    expect(main.secondary!.model, 'bbbbbbbb-model');
    expect(sec.welcome!.settings.segmentMinutes, 1);
    expect(sec.clock!.secondaryOffsetMs.abs(), lessThan(50));
  });

  test('full recording writes a manifest that lists both phones', () async {
    await pair();
    expect(await main.startRecording(), isTrue);
    await eventually(() => secCam.recording, reason: 'secondary recording');
    expect(mainCam.locked && secCam.locked, isTrue);

    await mainCam.finishSegment();
    await secCam.finishSegment();
    await main.stopRecording();

    final id = main.current!.recordingId;
    await eventually(() => main.manifestsWritten.contains(id), reason: 'manifest');
    final dir = mainStore.recordingDir(main.gameId, id);
    final manifest = jsonDecode(File('${dir.path}/manifest.json').readAsStringSync()) as Map;

    expect(manifest['gameId'], main.gameId);
    expect(manifest['sessionId'], id);
    final devices = manifest['devices'] as List;
    expect(devices.map((d) => d['role']), ['main', 'secondary']);
    for (final d in devices) {
      final segs = d['segments'] as List;
      expect(segs.length, 2);
      expect(segs.map((s) => s['index']), [0, 1]);
      expect(segs.every((s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s['sha256'] as String)), isTrue);
      expect(segs.first['objectKey'],
          'games/${main.gameId}/recordings/$id/${d['deviceId']}/${d['deviceId']}_000.mp4');
    }
    expect(devices[1]['platform'], 'android');
    expect((manifest['clockSync'] as Map)['samples'], greaterThan(0));

    final out = Platform.environment['SBV_MANIFEST_OUT'];
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

    // Secondary is stopped by hand, then comes back in range.
    await sec.stopLocally();
    links.connect();

    final id = main.current!.recordingId;
    await eventually(() => main.manifestsWritten.contains(id),
        reason: 'manifest after reconnect');
    expect(main.current!.peer!.segments.length, 2);
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
    expect(main.manifestsWritten, isEmpty);
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

  test('link state drives the Secondary phase', () async {
    expect(sec.phase, SecondaryPhase.connecting);
    links.connect();
    await eventually(() => sec.phase == SecondaryPhase.ready);
    links.disconnect();
    expect(links.secondary.state.value, LinkState.searching);
    expect(sec.phase, SecondaryPhase.connecting);
  });
}
