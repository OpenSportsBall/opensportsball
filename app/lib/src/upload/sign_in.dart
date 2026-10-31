// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Linking this phone by signing in (or signing up) instead of scanning a
/// QR code (docs/API.md, "Signing in from the app"): Cognito managed login
/// in a browser sheet, then a link code fetched with the sign-in token and
/// redeemed as if scanned. Only the device token is kept.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import 'account.dart';

/// The website the app signs in to unless people type another. Builds for
/// another deployment pass `--dart-define=OSB_SITE=https://...`.
const defaultSiteUrl = String.fromEnvironment('OSB_SITE', defaultValue: 'https://opensportsball.com');

/// Where managed login sends the browser back to (infra's
/// `APP_LOGIN_CALLBACK`).
const loginCallback = 'opensportsball://auth';

/// The parts of a website's `/config.json` the app needs.
class SiteConfig {
  const SiteConfig({required this.apiUrl, required this.appClientId, required this.cognitoDomain});
  final String apiUrl;
  final String appClientId;
  final String cognitoDomain;
}

/// People closed the sign-in sheet; not an error to show.
class SignInCanceled implements Exception {
  const SignInCanceled();
}

/// Opens [url] in a browser sheet and returns the URL it was sent back to,
/// on [callbackScheme]. Throws [SignInCanceled] when people close it.
typedef OpenLogin = Future<String> Function(Uri url, String callbackScheme);

Future<String> _browserSheet(Uri url, String callbackScheme) async {
  try {
    return await FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackScheme,
      // Nothing to remember in the browser: the phone keeps its own token.
      options: const FlutterWebAuth2Options(preferEphemeral: true),
    );
  } on PlatformException catch (e) {
    if (e.code == 'CANCELED') throw const SignInCanceled();
    throw LinkException('Could not open the sign-in page (${e.message ?? e.code}).');
  }
}

/// `https://example.com/`, `example.com` → `https://example.com`; null if
/// it can't be a website address.
String? normalizeSiteUrl(String typed) {
  var s = typed.trim().replaceAll(RegExp(r'/+$'), '');
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  return isAcceptableApiUrl(s) ? s : null;
}

/// The account's email from an ID token, or null. The token came straight
/// from Cognito over HTTPS, so it is not verified again here.
String? emailFromIdToken(String? idToken) {
  final parts = idToken?.split('.');
  if (parts == null || parts.length != 3) return null;
  try {
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final email = (claims as Map)['email'];
    return email is String ? email : null;
  } on Object {
    return null;
  }
}

class AppSignIn {
  AppSignIn({required this.client, OpenLogin? openLogin, Random? random})
      : _openLogin = openLogin ?? _browserSheet,
        _random = random ?? Random.secure();

  final http.Client client;
  final OpenLogin _openLogin;
  final Random _random;

  /// Signs in at [siteUrl] (with [signUp], starting on "create account"),
  /// then links this phone to that account through [account]. Throws
  /// [SignInCanceled] or [LinkException].
  Future<AccountLink> signInAndLink(AccountManager account, {required String siteUrl, bool signUp = false}) async {
    final config = await loadConfig(siteUrl);
    final verifier = _randomString(64);
    final state = _randomString(32);
    final redirect = Uri.parse(loginCallback);
    final returned = Uri.parse(await _openLogin(
      Uri.parse('${config.cognitoDomain}/${signUp ? 'signup' : 'oauth2/authorize'}').replace(queryParameters: {
        'response_type': 'code',
        'client_id': config.appClientId,
        'redirect_uri': loginCallback,
        'scope': 'openid email profile',
        'state': state,
        'code_challenge': base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', ''),
        'code_challenge_method': 'S256',
      }),
      redirect.scheme,
    ));
    final q = returned.queryParameters;
    if (q['state'] != state) throw const LinkException('Sign-in was interrupted. Try again.');
    if (q['error'] != null) {
      throw LinkException('Sign-in failed (${q['error_description'] ?? q['error']}).');
    }
    final code = q['code'];
    if (code == null || code.isEmpty) throw const LinkException('Sign-in was interrupted. Try again.');

    final tokens = await _send(() => client.post(
          Uri.parse('${config.cognitoDomain}/oauth2/token'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'authorization_code',
            'client_id': config.appClientId,
            'code': code,
            'redirect_uri': loginCallback,
            'code_verifier': verifier,
          },
        ));
    if (tokens.statusCode != 200) {
      throw LinkException('Sign-in failed (${tokens.statusCode}). Try again.');
    }
    final String accessToken;
    final String? email;
    try {
      final b = (jsonDecode(tokens.body) as Map).cast<String, Object?>();
      accessToken = b['access_token'] as String;
      email = emailFromIdToken(b['id_token'] as String?);
    } on Object {
      throw const LinkException('The server sent an unexpected answer.');
    }

    // The same code the website would show, made for this phone.
    final res = await _send(() => client.post(
          apiUri(config.apiUrl, '/link-codes'),
          headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
        ));
    if (res.statusCode != 201) {
      throw LinkException('Could not link this phone (${res.statusCode}${serverMessage(res)}).');
    }
    final String linkCode;
    try {
      linkCode = (jsonDecode(res.body) as Map)['code'] as String;
    } on Object {
      throw const LinkException('The server sent an unexpected answer.');
    }
    return account.linkWith(LinkRequest(apiUrl: config.apiUrl, code: linkCode), email: email);
  }

  /// GET `<siteUrl>/config.json`. Throws [LinkException].
  Future<SiteConfig> loadConfig(String siteUrl) async {
    final res = await _send(() => client.get(Uri.parse('$siteUrl/config.json')));
    if (res.statusCode != 200) {
      throw LinkException('$siteUrl is not a OpenSportsBall website (${res.statusCode}).');
    }
    final Map<String, Object?> j;
    try {
      j = (jsonDecode(res.body) as Map).cast();
    } on Object {
      throw LinkException('$siteUrl is not a OpenSportsBall website.');
    }
    final api = j['apiUrl'], clientId = j['appClientId'], domain = j['cognitoDomain'];
    if (api is! String || !isAcceptableApiUrl(api) || domain is! String || !isAcceptableApiUrl(domain)) {
      throw LinkException('$siteUrl is not a OpenSportsBall website.');
    }
    if (clientId is! String || clientId.isEmpty) {
      throw const LinkException('That server does not support signing in from the app yet. '
          'Link with the QR code on the website instead.');
    }
    return SiteConfig(
      apiUrl: api.replaceAll(RegExp(r'/+$'), ''),
      appClientId: clientId,
      cognitoDomain: domain.replaceAll(RegExp(r'/+$'), ''),
    );
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const LinkException('The server did not answer. Check the internet connection.', offline: true);
    } on SocketException {
      throw const LinkException('Could not reach the server. Check the internet connection.', offline: true);
    } on http.ClientException {
      throw const LinkException('Could not reach the server. Check the internet connection.', offline: true);
    }
  }

  static const _unreserved = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  String _randomString(int length) =>
      String.fromCharCodes([for (var i = 0; i < length; i++) _unreserved.codeUnitAt(_random.nextInt(_unreserved.length))]);
}
