// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:opensportsball/src/model.dart';
import 'package:opensportsball/src/protocol/messages.dart';
import 'package:opensportsball/src/role.dart';
import 'package:opensportsball/src/session/main_controller.dart';
import 'package:opensportsball/src/session/secondary_controller.dart';
import 'package:opensportsball/src/storage/manifest.dart';
import 'package:opensportsball/src/storage/store.dart';
import 'package:opensportsball/src/upload/account.dart';

import 'fakes.dart';

/// Main gives Secondary a recording grant while they pair, so Secondary
/// uploads into Main's account whatever account it is on.
/// Server calls about grants, leaving out Main restocking its grant
/// tickets when its screen opens.
List<String> grantCalls(FakeGrantServer server) => server.log.where((l) => l != 'POST /grant-tickets').toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGrantServer server;
  late FakeLinkPair links;

  setUp(() {
    server = FakeGrantServer();
    links = FakeLinkPair();
  });

  Future<(MainController, SecondaryController)> pair(AccountManager mainAcct, AccountManager secAcct,
      {bool connect = true}) async {
    final main = MainController(
      store: mainAcct.store,
      camera: FakeCamera(),
      linkFactory: (_) => links.main,
      account: mainAcct,
      grantRetryEvery: const Duration(milliseconds: 50),
    );
    final sec = SecondaryController(
      store: secAcct.store,
      camera: FakeCamera(),
      gameId: main.gameId,
      linkFactory: (_) => links.secondary,
      account: secAcct,
      pingsPerRound: 2,
      pingSpacing: const Duration(milliseconds: 1),
    );
    addTearDown(() async {
      await main.dispose();
      await sec.dispose();
    });
    await main.init();
    await sec.init();
    if (connect) links.connect();
    return (main, sec);
  }

  Future<AccountManager> account(String store, {String? accountId}) async =>
      fakeAccount(await tempStore(store), server.client, accountId: accountId);

  test('a Secondary on no account gets Main\'s grant and stays unlinked', () async {
    final secAcct = await account('bbbbbbbb');
    final (main, sec) = await pair(await account('aaaaaaaa', accountId: 'acc-main'), secAcct);
    await eventually(() => main.grantState == GrantState.delivered, reason: 'delivered');
    expect(grantCalls(server), ['POST /games/${main.gameId}/grants']);

    final g = (await secAcct.grantFor(main.gameId))!;
    expect(g.accountId, 'acc-main');
    expect(g.token, startsWith('osbg_'));
    expect(g.apiUrl, 'https://api.test');
    expect(sec.grant!.token, g.token);
    expect(secAcct.linked, isFalse);
  });

  test('a Secondary on another account keeps it, and still gets the grant', () async {
    final secAcct = await account('bbbbbbbb', accountId: 'acc-other');
    final (main, _) = await pair(await account('aaaaaaaa', accountId: 'acc-main'), secAcct);
    await eventually(() => main.grantState == GrantState.delivered);
    expect((await secAcct.grantFor(main.gameId))!.accountId, 'acc-main');
    expect(secAcct.link!.accountId, 'acc-other');
  });

  test('a reconnect re-sends the same grant without asking the server', () async {
    final (main, _) = await pair(await account('aaaaaaaa', accountId: 'acc-main'), await account('bbbbbbbb'));
    await eventually(() => main.grantState == GrantState.delivered);
    links.disconnect();
    links.connect();
    await eventually(() => links.secondary.sent.whereType<Hello>().length == 2);
    expect(grantCalls(server), hasLength(1));
  });

  test('without internet Main keeps trying while they are paired', () async {
    server.offline = true;
    final (main, sec) = await pair(await account('aaaaaaaa', accountId: 'acc-main'), await account('bbbbbbbb'));
    await eventually(() => main.grantState == GrantState.waitingForInternet);
    expect(sec.grant, isNull);
    server.offline = false;
    await eventually(() => main.grantState == GrantState.delivered, reason: 'retried');
    expect(sec.grant, isNotNull);
  });

  test('an unlinked Main says so and asks nothing', () async {
    final (main, sec) = await pair(await account('aaaaaaaa'), await account('bbbbbbbb'));
    await eventually(() => main.grantState == GrantState.mainNotLinked);
    expect(grantCalls(server), isEmpty);
    expect(sec.grant, isNull);
  });

  test('Secondary refuses a grant for another game', () async {
    final secAcct = await account('bbbbbbbb');
    final (main, sec) = await pair(await account('aaaaaaaa', accountId: 'acc-main'), secAcct);
    await eventually(() => main.grantState == GrantState.delivered);
    await links.main.send(GrantMsg(RecordingGrant(
        apiUrl: 'https://api.test',
        token: 'osbg_x',
        accountId: 'acc-other',
        gameId: 'another-game',
        expiresAt: DateTime.now().add(const Duration(days: 1)))));
    await eventually(() => links.secondary.sent.whereType<GrantAck>().any((a) => !a.ok));
    expect(sec.grantError, contains('another game'));
    expect(await secAcct.grantFor('another-game'), isNull);
    expect(sec.grant!.accountId, 'acc-main', reason: 'Main\'s grant is kept');
    expect(main.grantState, GrantState.delivered, reason: 'an ack for another game is ignored');
  });

  test('the manifest names Secondary only if it confirmed the grant', () {
    const id = DeviceIdentity(deviceId: 'main-1', platform: 'android', model: 'Pixel');
    const video =
        VideoInfo(width: 3840, height: 2160, nominalFps: 30, codec: 'hevc', lens: 'ultrawide', bitrateBps: 1);
    LocalRecording rec({required bool granted}) => LocalRecording(
          recordingId: 'r',
          gameId: 'g',
          role: DeviceRole.main,
          device: id,
          createdAtMs: 0,
          video: video,
          startedAtDeviceMs: 0,
          stoppedAtMs: 1,
          segments: const [
            SegmentRecord(
                index: 0, fileName: 'main-1_000.mp4', bytes: 1, sha256: 'a', startedAtDeviceMs: 0, durationMs: 1),
          ],
          peer: PeerRecord(
              device: const DeviceIdentity(deviceId: 'sec-1', platform: 'android', model: 'Pixel'),
              video: video,
              granted: granted),
        );
    expect((buildManifest(rec(granted: true))!['devices'] as List).length, 2);
    expect((buildManifest(rec(granted: false))!['devices'] as List).length, 1);
    expect(PeerRecord.fromJson({'device': id.toJson(), 'segments': []}).granted, isTrue,
        reason: 'recordings from before grants');
  });
}
