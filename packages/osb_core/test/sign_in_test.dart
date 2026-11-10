// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';
import 'package:test/test.dart';

String jwt(Map<String, Object?> claims) =>
    'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

const config = SiteConfig(
  siteUrl: 'https://osb.test',
  apiUrl: 'https://api.osb.test',
  cognitoDomain: 'https://login.osb.test',
  desktopClientId: 'desk',
);

void main() {
  test('reads config.json, desktop client included', () async {
    final client = MockClient((r) async {
      expect(r.url.toString(), 'https://osb.test/config.json');
      return http.Response(
          jsonEncode({
            'apiUrl': 'https://api.osb.test/',
            'cognitoDomain': 'https://login.osb.test',
            'appClientId': 'app',
            'desktopClientId': 'desk'
          }),
          200);
    });
    final c = await loadSiteConfig(client, 'https://osb.test');
    expect(c.apiUrl, 'https://api.osb.test');
    expect(c.desktopClientId, 'desk');
    expect(normalizeSiteUrl('osb.test/'), 'https://osb.test');
    expect(normalizeSiteUrl('http://osb.test'), isNull);
  });

  test('signs in with PKCE and refuses a reply to another attempt', () async {
    late Uri opened;
    final client = MockClient((r) async {
      final form = Uri.splitQueryString(r.body);
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'the-code');
      expect(form['code_verifier'], hasLength(64));
      return http.Response(
          jsonEncode({
            'access_token': jwt({'sub': 'acct-1'}),
            'id_token': jwt({'email': 'a@b.test'}),
            'refresh_token': 'r1',
            'expires_in': 3600,
          }),
          200);
    });
    final t = await signIn(
      client: client,
      cognitoDomain: config.cognitoDomain,
      clientId: 'desk',
      redirectUri: 'opensportsball://desktop-auth',
      random: Random(1),
      openLogin: (url, scheme) async {
        opened = url;
        expect(scheme, 'opensportsball');
        return 'opensportsball://desktop-auth?code=the-code&state=${url.queryParameters['state']}';
      },
    );
    expect(opened.path, '/oauth2/authorize');
    expect(opened.queryParameters['code_challenge_method'], 'S256');
    expect(t.email, 'a@b.test');
    expect(t.accountId, 'acct-1');
    expect(t.refreshToken, 'r1');

    final req = LoginRequest(cognitoDomain: 'https://l', clientId: 'c', redirectUri: 'x://y');
    expect(() => req.codeFrom('x://y?code=c&state=other'), throwsA(isA<OsbException>()));
    expect(() => req.codeFrom('x://y?error=access_denied&state=${req.state}'), throwsA(isA<OsbException>()));
  });

  test('refreshes the access token before it expires and keeps the refresh token', () async {
    var now = DateTime.utc(2026, 11, 10, 12);
    var refreshes = 0;
    final client = MockClient((r) async {
      if (r.url.path == '/oauth2/token') {
        refreshes++;
        expect(Uri.splitQueryString(r.body)['refresh_token'], 'r1');
        return http.Response(jsonEncode({'access_token': 'a2', 'expires_in': 3600}), 200);
      }
      expect(r.headers['authorization'], 'Bearer a2');
      return http.Response(
          jsonEncode({
            'games': [
              {'gameId': 'g1', 'createdAt': '2026-11-01T00:00:00Z', 'recordingCount': 1, 'status': 'ready'}
            ]
          }),
          200);
    });
    final store = MemoryTokenStore();
    final s = Session(
      config: config,
      clientId: 'desk',
      client: client,
      store: store,
      now: () => now,
      tokens: Tokens(accessToken: 'a1', refreshToken: 'r1', expiresAt: now.add(const Duration(minutes: 1))),
    );
    final games = await s.games();
    expect(games.single.gameId, 'g1');
    expect(refreshes, 1);
    expect(s.tokens.refreshToken, 'r1');

    // Saved: a restart finds the same session.
    final back = await Session.restore(store, client, now: () => now);
    expect(back!.tokens.accessToken, 'a2');
    expect(back.config.desktopClientId, 'desk');

    // A refused refresh means signing in again.
    now = now.add(const Duration(hours: 2));
    final refused = Session(
      config: config,
      clientId: 'desk',
      client: MockClient((r) async => http.Response('{"error":"invalid_grant"}', 400)),
      store: store,
      now: () => now,
      tokens: Tokens(accessToken: 'a1', refreshToken: 'r1', expiresAt: now),
    );
    expect(refused.games(), throwsA(isA<SignedOut>()));
  });
}
