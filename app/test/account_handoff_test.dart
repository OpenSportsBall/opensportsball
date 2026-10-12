// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opensportsball/src/session/main_controller.dart';
import 'package:opensportsball/src/session/secondary_controller.dart';
import 'package:opensportsball/src/upload/account.dart';

import 'fakes.dart';

/// Main links Secondary to Main's account while they pair.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const api = 'https://api.test';

  /// The two link routes: `POST /devices/link-codes` for Main's token,
  /// `POST /devices/link` with that code. [secondaryOwner] simulates
  /// Secondary already belonging to another account (409).
  late List<String> log;
  late String? secondaryOwner;
  late http.Client client;

  setUp(() {
    log = [];
    secondaryOwner = null;
    final codes = <String, String>{};
    client = MockClient((req) async {
      log.add('${req.method} ${req.url.path}');
      http.Response json(int code, Object body) => http.Response(jsonEncode(body), code);
      if (req.url.path == '/devices/link-codes') {
        if (req.headers['Authorization'] != 'Bearer osbd_main') return json(401, {});
        codes['HJKMNPQR'] = 'acc-main';
        return json(201, {'code': 'HJKMNPQR', 'expiresAt': '', 'linkUri': ''});
      }
      if (req.url.path == '/devices/link') {
        final b = jsonDecode(req.body) as Map;
        final acct = codes.remove(b['code']);
        if (acct == null) return json(410, {});
        if (secondaryOwner != null && secondaryOwner != acct) return json(409, {});
        return json(200, {'deviceToken': 'osbd_secondary', 'accountId': acct});
      }
      return json(404, {});
    });
  });

  Future<AccountManager> account(String name, AccountLink? link) async {
    final store = await tempStore(name);
    final secrets = MemorySecretStore();
    if (link != null) secrets.values['account_link'] = jsonEncode(link.toJson());
    final a = AccountManager(store: store, secrets: secrets, client: client);
    await a.load();
    return a;
  }

  Future<(MainController, SecondaryController)> pair(AccountManager mainAcct, AccountManager secAcct) async {
    final links = FakeLinkPair();
    final main = MainController(
        store: mainAcct.store, camera: FakeCamera(), linkFactory: (_) => links.main, account: mainAcct);
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

  const mainLink = AccountLink(apiUrl: api, deviceToken: 'osbd_main', accountId: 'acc-main');

  test('an unlinked Secondary is linked to Main\'s account', () async {
    final secAcct = await account('bbbbbbbb', null);
    final (main, sec) = await pair(await account('aaaaaaaa', mainLink), secAcct);
    await eventually(() => main.secondaryAccount == SecondaryAccount.linked, reason: 'linked');
    expect(secAcct.link!.accountId, 'acc-main');
    expect(secAcct.link!.apiUrl, api);
    expect(sec.linkedByMain, isTrue);
    expect(log, ['POST /devices/link-codes', 'POST /devices/link']);
  });

  test('a Secondary already on Main\'s account is left alone', () async {
    final secAcct = await account(
        'bbbbbbbb', const AccountLink(apiUrl: api, deviceToken: 'osbd_x', accountId: 'acc-main'));
    final (main, _) = await pair(await account('aaaaaaaa', mainLink), secAcct);
    await eventually(() => main.secondaryAccount == SecondaryAccount.linked);
    expect(log, isEmpty);
  });

  test('a Secondary owned by another account is not moved, and Main says so', () async {
    secondaryOwner = 'acc-other';
    final secAcct = await account(
        'bbbbbbbb', const AccountLink(apiUrl: api, deviceToken: 'osbd_o', accountId: 'acc-other'));
    final (main, sec) = await pair(await account('aaaaaaaa', mainLink), secAcct);
    await eventually(() => main.secondaryAccount == SecondaryAccount.failed);
    expect(main.secondaryAccountError, contains('different account'));
    expect(secAcct.link!.accountId, 'acc-other');
    expect(sec.linkedByMain, isFalse);
  });

  test('an unlinked Main reports that instead of linking', () async {
    final (main, _) = await pair(await account('aaaaaaaa', null), await account('bbbbbbbb', null));
    await eventually(() => main.secondaryAccount == SecondaryAccount.mainNotLinked);
    expect(log, isEmpty);
  });
}
