// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:opensportsball/src/session/main_controller.dart';
import 'package:opensportsball/src/session/secondary_controller.dart';
import 'package:opensportsball/src/upload/account.dart';

import 'fakes.dart';

/// Pairing at a field without signal: Main hands Secondary a grant ticket
/// it fetched earlier, and the phones bind it once they reach the internet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGrantServer server;
  late FakeLinkPair links;

  setUp(() {
    server = FakeGrantServer();
    links = FakeLinkPair();
  });

  Future<AccountManager> account(String store, {String? accountId}) async =>
      fakeAccount(await tempStore(store), server.client, accountId: accountId);

  Future<(MainController, SecondaryController)> pair(AccountManager mainAcct, AccountManager secAcct) async {
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
    links.connect();
    return (main, sec);
  }

  test('Main without signal hands over a ticket; both phones bind it once online', () async {
    final mainAcct = await account('aaaaaaaa', accountId: 'acc-main');
    await mainAcct.refillTickets(); // e.g. at home on Wi-Fi
    expect(mainAcct.ticketsInStock, AccountManager.ticketStock);

    server.offline = true; // at the field
    final secAcct = await account('bbbbbbbb');
    final (main, sec) = await pair(mainAcct, secAcct);
    await eventually(() => main.grantState == GrantState.delivered, reason: 'ticket delivered');
    expect(main.grantIsTicket, isTrue);
    final g = (await secAcct.grantFor(main.gameId))!;
    expect(g.unredeemed, isTrue);
    expect(g.accountId, 'acc-main');
    expect(mainAcct.ticketsInStock, AccountManager.ticketStock - 1);
    expect(mainAcct.pendingRedemptions, 1);

    // Delivered once; later retries don't ask the server for a competing grant.
    final grantAsks = server.log.where((l) => l.endsWith('/grants')).length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.log.where((l) => l.endsWith('/grants')).length, grantAsks);

    // Home again: Secondary binds it to itself, then Main finds it bound.
    server.offline = false;
    final redeemed = await secAcct.redeemGrant(g, deviceId: secAcct.store.identity.deviceId);
    expect(redeemed.unredeemed, isFalse);
    expect((await secAcct.grantFor(main.gameId))!.unredeemed, isFalse);
    expect(server.redeemed[g.token], (main.gameId, secAcct.store.identity.deviceId));

    await mainAcct.redeemPending();
    expect(mainAcct.pendingRedemptions, 0);
  });

  test('Main with no tickets and no signal keeps waiting, and says why', () async {
    server.offline = true;
    final mainAcct = await account('aaaaaaaa', accountId: 'acc-main');
    final (main, sec) = await pair(mainAcct, await account('bbbbbbbb'));
    await eventually(() => main.grantState == GrantState.waitingForInternet);
    expect(mainAcct.ticketsInStock, 0);
    expect(sec.grant, isNull);
  });

  test('tickets and pending bindings survive a restart; refused ones are dropped', () async {
    final store = await tempStore('cccccccc');
    final secrets = MemorySecretStore();
    secrets.values['account_link'] = '{"apiUrl":"https://api.test","deviceToken":"osbd_acc-main","accountId":"acc-main"}';
    final a = AccountManager(store: store, secrets: secrets, client: server.client);
    await a.load();
    await a.refillTickets();
    final g = await a.grantFromTicket(gameId: 'game-1', deviceId: 'sec-1');
    expect(g!.unredeemed, isTrue);

    final restarted = AccountManager(store: store, secrets: secrets, client: server.client);
    await restarted.load();
    expect(restarted.ticketsInStock, AccountManager.ticketStock - 1);
    expect(restarted.pendingRedemptions, 1);

    server.offline = true;
    await restarted.redeemPending();
    expect(restarted.pendingRedemptions, 1, reason: 'kept while offline');

    server.offline = false;
    server.refuseRedeem = true;
    await restarted.redeemPending();
    expect(restarted.pendingRedemptions, 0, reason: 'retrying a refusal will not help');
  });

  test('unlinking forgets the tickets but keeps bindings still owed', () async {
    final a = await account('dddddddd', accountId: 'acc-main');
    await a.refillTickets();
    await a.grantFromTicket(gameId: 'game-1', deviceId: 'sec-1');
    await a.unlink(force: true);
    expect(a.ticketsInStock, 0);
    expect(a.pendingRedemptions, 1);
    expect(await a.grantFromTicket(gameId: 'game-2', deviceId: 'sec-1'), isNull);
  });
}
