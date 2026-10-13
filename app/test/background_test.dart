// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opensportsball/src/session/activity.dart';
import 'package:opensportsball/src/upload/account.dart';
import 'package:opensportsball/src/upload/background.dart';
import 'package:opensportsball/src/upload/network.dart';
import 'package:opensportsball/src/upload/upload_service.dart';

import 'fakes.dart';
import 'upload_fakes.dart';

class FakeRunner implements BackgroundRunner {
  final calls = <String>[];
  final statuses = <BackgroundStatus>[];
  bool allowStart = true;
  bool alive = true;
  bool running = false;

  @override
  Future<bool> start(BackgroundStatus status) async {
    calls.add('start');
    statuses.add(status);
    running = allowStart;
    return allowStart;
  }

  @override
  Future<bool> update(BackgroundStatus status) async {
    calls.add('update');
    statuses.add(status);
    if (!alive) running = false;
    return alive;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    running = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(UploadService, FakeNetwork)> setUp(String name, {bool linked = true}) async {
    final store = await tempStore(name);
    final backend = FakeBackend(partSize: 128);
    final secrets = MemorySecretStore();
    if (linked) {
      secrets.values['account_link'] = jsonEncode(
          const AccountLink(apiUrl: apiUrl, deviceToken: deviceToken, accountId: accountId).toJson());
    }
    final account = AccountManager(store: store, secrets: secrets, client: backend.client);
    await account.load();
    await writeRecording(store, recordingId: 'rec-1', sizes: [300, 500]);
    final network = FakeNetwork();
    final uploads = UploadService(
      store: store,
      account: account,
      client: backend.client,
      network: network,
      activity: DeviceActivity(),
      chunkBytes: 50,
    );
    return (uploads, network);
  }

  test('runs while uploading, with progress, and stops when done', () async {
    final (uploads, _) = await setUp('aaaaaaaa');
    final runner = FakeRunner();
    final bg = BackgroundUploads(uploads: uploads, runner: runner, updateInterval: Duration.zero)..start();
    expect(runner.calls, isEmpty, reason: 'nothing scanned yet');

    expect(await uploads.runPass(), PassResult.done);
    await eventually(() => runner.calls.isNotEmpty && runner.calls.last == 'stop');

    expect(runner.calls.first, 'start');
    expect(runner.statuses.first.title, 'Uploading 1 recording');
    expect(runner.statuses.first.busy, isTrue);
    expect(runner.calls.where((c) => c == 'update'), isNotEmpty);
    final progress = [for (final s in runner.statuses) s.permille];
    expect(progress, orderedEquals([...progress]..sort()), reason: 'never goes back');
    expect(progress.last, greaterThan(500));
    expect(runner.statuses.last.text, contains(' of '));
    expect(bg.active, isFalse);
    bg.dispose();
  });

  test('stays alive while waiting for the network, without the wake lock', () async {
    final (uploads, network) = await setUp('bbbbbbbb');
    network.kind = NetworkKind.offline;
    final runner = FakeRunner();
    final bg = BackgroundUploads(uploads: uploads, runner: runner)..start();
    expect(await uploads.runPass(), PassResult.blocked);
    await eventually(() => runner.calls.isNotEmpty);
    expect(runner.calls, ['start']);
    expect(runner.statuses.single.title, UploadPhase.offline.label);
    expect(runner.statuses.single.busy, isFalse);
    expect(bg.active, isTrue);

    uploads.setPaused(true); // the user paused: let the app sleep
    await uploads.runPass();
    await eventually(() => runner.calls.last == 'stop');
    bg.dispose();
  });

  test('does not start for recordings that cannot upload', () async {
    final (uploads, _) = await setUp('cccccccc', linked: false);
    final runner = FakeRunner();
    BackgroundUploads(uploads: uploads, runner: runner).start();
    expect(await uploads.runPass(), PassResult.blocked);
    expect(uploads.phase, UploadPhase.notLinked);
    await pumpEventQueue();
    expect(runner.calls, isEmpty);
  });

  test('after the OS refuses, asks again later or when the app is opened', () async {
    final (uploads, network) = await setUp('dddddddd');
    network.kind = NetworkKind.offline;
    var now = DateTime(2026, 10, 11, 12);
    final runner = FakeRunner()..allowStart = false;
    final bg = BackgroundUploads(uploads: uploads, runner: runner, now: () => now)..start();
    expect(await uploads.runPass(), PassResult.blocked);
    await eventually(() => runner.calls.isNotEmpty);
    expect(runner.calls, ['start']);

    // Changes soon after don't ask again.
    uploads.setPaused(false);
    await pumpEventQueue();
    expect(runner.calls, ['start']);

    // The app came back on screen.
    runner.allowStart = true;
    bg.resumed();
    await eventually(() => runner.calls.length == 2);
    expect(bg.active, isTrue);

    // The OS ended it (time limit); the next update notices.
    runner.alive = false;
    now = now.add(const Duration(seconds: 5));
    network.kind = NetworkKind.metered;
    expect(await uploads.runPass(), PassResult.blocked);
    expect(uploads.phase, UploadPhase.waitingForWifi);
    await eventually(() => runner.calls.last == 'update');
    await pumpEventQueue();
    expect(bg.active, isFalse);

    // Asked again once the wait is over.
    runner.alive = true;
    now = now.add(const Duration(seconds: 31));
    uploads.setPaused(false);
    await eventually(() => runner.calls.last == 'start');
    expect(bg.active, isTrue);
    bg.dispose();
    expect(runner.calls.last, 'stop');
  });
}
