// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opensportsball/src/upload/account.dart';
import 'package:opensportsball/src/upload/sign_in.dart';

import 'fakes.dart';

const site = 'https://site.test';
const login = 'https://auth.test';

String idToken(Map<String, Object?> claims) =>
    ['{"alg":"none"}', jsonEncode(claims), ''].map((p) => base64Url.encode(utf8.encode(p))).join('.');

/// The website, managed login and the API (docs/API.md, "Signing in from
/// the app").
class FakeServer {
  FakeServer({this.config});

  Map<String, Object?>? config;
  final requests = <http.Request>[];
  late final http.Client client = MockClient((req) async {
    requests.add(req);
    switch ('${req.method} ${req.url.origin}${req.url.path}') {
      case 'GET $site/config.json':
        return http.Response(
            jsonEncode(config ??
                {'apiUrl': 'https://api.test/', 'appClientId': 'app-client', 'cognitoDomain': '$login/'}),
            200);
      case 'POST $login/oauth2/token':
        return http.Response(
            jsonEncode({'access_token': 'access-1', 'id_token': idToken({'email': 'coach@example.com'})}), 200);
      case 'POST https://api.test/link-codes':
        if (req.headers['Authorization'] != 'Bearer access-1') return http.Response('{}', 401);
        return http.Response(jsonEncode({'code': 'ABCDEFGH', 'expiresAt': '2026-10-30T00:10:00Z'}), 201);
      case 'POST https://api.test/devices/link':
        return http.Response(jsonEncode({'deviceToken': 'osbd_new', 'accountId': 'acc-9', 'email': null}), 200);
    }
    return http.Response('{}', 404);
  });
}

void main() {
  test('signs in, then links with a code made for this phone', () async {
    final server = FakeServer();
    final store = await tempStore('signin01');
    final account = AccountManager(store: store, secrets: MemorySecretStore(), client: server.client);
    await account.load();
    late Uri opened;
    final signIn = AppSignIn(
      client: server.client,
      openLogin: (url, scheme) async {
        opened = url;
        expect(scheme, 'opensportsball');
        return '$loginCallback?code=auth-code&state=${url.queryParameters['state']}';
      },
    );

    final link = await signIn.signInAndLink(account, siteUrl: site);

    expect(opened.toString(), startsWith('$login/oauth2/authorize?'));
    final q = opened.queryParameters;
    expect(q['client_id'], 'app-client');
    expect(q['redirect_uri'], loginCallback);
    expect(q['code_challenge_method'], 'S256');
    final token = server.requests.singleWhere((r) => r.url.path == '/oauth2/token').bodyFields;
    expect(token['code'], 'auth-code');
    expect(token['client_id'], 'app-client');
    // PKCE: the verifier sent now matches the challenge sent before.
    expect(base64Url.encode(sha256.convert(ascii.encode(token['code_verifier']!)).bytes).replaceAll('=', ''),
        q['code_challenge']);
    final linked = jsonDecode(server.requests.singleWhere((r) => r.url.path == '/devices/link').body) as Map;
    expect(linked['code'], 'ABCDEFGH');
    expect(linked['deviceId'], store.identity.deviceId);

    expect(link.apiUrl, 'https://api.test');
    expect(link.deviceToken, 'osbd_new');
    // The server's link codes carry no email for an access token; the ID
    // token's is shown instead.
    expect(link.email, 'coach@example.com');
    expect(account.linked, isTrue);
  });

  test('create account starts on the sign-up page', () async {
    final server = FakeServer();
    final account = AccountManager(store: await tempStore('signin02'), secrets: MemorySecretStore(), client: server.client);
    late Uri opened;
    await AppSignIn(
      client: server.client,
      openLogin: (url, _) async {
        opened = url;
        return '$loginCallback?code=c&state=${url.queryParameters['state']}';
      },
    ).signInAndLink(account, siteUrl: site, signUp: true);
    expect(opened.path, '/signup');
  });

  test('a redirect with someone else\'s state is refused before any token is fetched', () async {
    final server = FakeServer();
    final account = AccountManager(store: await tempStore('signin03'), secrets: MemorySecretStore(), client: server.client);
    final signIn = AppSignIn(client: server.client, openLogin: (_, __) async => '$loginCallback?code=c&state=other');
    await expectLater(signIn.signInAndLink(account, siteUrl: site), throwsA(isA<LinkException>()));
    expect(server.requests.where((r) => r.url.path == '/oauth2/token'), isEmpty);
    expect(account.linked, isFalse);
  });

  test('closing the sheet is a cancel, not an error', () async {
    final server = FakeServer();
    final account = AccountManager(store: await tempStore('signin04'), secrets: MemorySecretStore(), client: server.client);
    final signIn = AppSignIn(client: server.client, openLogin: (_, __) async => throw const SignInCanceled());
    await expectLater(signIn.signInAndLink(account, siteUrl: site), throwsA(isA<SignInCanceled>()));
  });

  test('a server without an app client says to use the QR code', () async {
    final server = FakeServer(config: {'apiUrl': 'https://api.test', 'cognitoDomain': login});
    await expectLater(
      AppSignIn(client: server.client, openLogin: (_, __) async => fail('no sheet')).loadConfig(site),
      throwsA(isA<LinkException>().having((e) => e.message, 'message', contains('QR code'))),
    );
  });

  test('site addresses', () {
    expect(normalizeSiteUrl(' opensportsball.com/ '), 'https://opensportsball.com');
    expect(normalizeSiteUrl('https://example.org'), 'https://example.org');
    expect(normalizeSiteUrl('http://example.org'), isNull);
    expect(normalizeSiteUrl(''), isNull);
    expect(emailFromIdToken(idToken({'email': 'a@b.c'})), 'a@b.c');
    expect(emailFromIdToken('junk'), isNull);
  });
}
