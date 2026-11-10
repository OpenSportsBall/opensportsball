// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Signing in on Cognito's managed login pages (authorization code + PKCE,
/// docs/API.md "People, on the website"), and keeping a signed-in session's
/// tokens fresh. Opening the browser is the app's part ([OpenLogin]).
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'site.dart';

/// People closed the sign-in page; not an error to show.
class SignInCanceled implements Exception {
  const SignInCanceled();
}

/// Opens [url] in a browser sheet and returns the URL it was sent back to,
/// on [callbackScheme]. Throws [SignInCanceled] when people close it.
typedef OpenLogin = Future<String> Function(Uri url, String callbackScheme);

/// The account's email from an ID token, or null. The token came straight
/// from Cognito over HTTPS, so it is not verified again here.
String? emailFromIdToken(String? idToken) => _claims(idToken)?['email'] as String?;

/// The account id (the token's `sub`), or null.
String? subFromToken(String? token) => _claims(token)?['sub'] as String?;

Map<String, Object?>? _claims(String? token) {
  final parts = token?.split('.');
  if (parts == null || parts.length != 3) return null;
  try {
    return (jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map).cast();
  } on Object {
    return null;
  }
}

const _unreserved = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

String randomString(Random random, int length) =>
    String.fromCharCodes([for (var i = 0; i < length; i++) _unreserved.codeUnitAt(random.nextInt(_unreserved.length))]);

/// One sign-in attempt's secrets and the managed-login URL that goes with
/// them.
class LoginRequest {
  LoginRequest({
    required this.cognitoDomain,
    required this.clientId,
    required this.redirectUri,
    bool signUp = false,
    this.chooseAccount = false,
    Random? random,
  })  : verifier = randomString(random ?? Random.secure(), 64),
        state = randomString(random ?? Random.secure(), 32),
        _signUp = signUp;

  final String cognitoDomain;
  final String clientId;
  final String redirectUri;
  final String verifier;
  final String state;
  final bool _signUp;

  /// Show the login form even when the browser is still signed in
  /// (`prompt=login`), so another account can be chosen.
  final bool chooseAccount;

  Uri get url => Uri.parse('$cognitoDomain/${_signUp ? 'signup' : 'oauth2/authorize'}').replace(
        queryParameters: {
          'response_type': 'code',
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'scope': 'openid email profile',
          'state': state,
          'code_challenge': base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', ''),
          'code_challenge_method': 'S256',
          if (chooseAccount) 'prompt': 'login',
        },
      );

  /// The code from the URL managed login sent the browser back to. Throws
  /// [OsbException].
  String codeFrom(String returnedUrl) {
    final q = Uri.parse(returnedUrl).queryParameters;
    if (q['state'] != state) throw const OsbException('Sign-in was interrupted. Try again.');
    if (q['error'] != null) throw OsbException('Sign-in failed (${q['error_description'] ?? q['error']}).');
    final code = q['code'];
    if (code == null || code.isEmpty) throw const OsbException('Sign-in was interrupted. Try again.');
    return code;
  }
}

/// Cognito's tokens for one signed-in person.
class Tokens {
  const Tokens({required this.accessToken, required this.expiresAt, this.idToken, this.refreshToken});

  final String accessToken;
  final DateTime expiresAt;
  final String? idToken;
  final String? refreshToken;

  String? get email => emailFromIdToken(idToken);
  String? get accountId => subFromToken(accessToken);

  /// Fresh for at least another [margin].
  bool freshAt(DateTime now, {Duration margin = const Duration(minutes: 2)}) => now.add(margin).isBefore(expiresAt);

  factory Tokens.fromTokenResponse(Map<String, Object?> b, DateTime now, {String? keepRefreshToken}) => Tokens(
        accessToken: b['access_token'] as String,
        idToken: b['id_token'] as String?,
        // A refresh answer has no new refresh token: keep the old one.
        refreshToken: (b['refresh_token'] as String?) ?? keepRefreshToken,
        expiresAt: now.add(Duration(seconds: (b['expires_in'] as num?)?.toInt() ?? 3600)),
      );

  factory Tokens.fromJson(Map<String, Object?> j) => Tokens(
        accessToken: j['accessToken'] as String,
        idToken: j['idToken'] as String?,
        refreshToken: j['refreshToken'] as String?,
        expiresAt: DateTime.parse(j['expiresAt'] as String),
      );

  Map<String, Object?> toJson() => {
        'accessToken': accessToken,
        if (idToken != null) 'idToken': idToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };
}

/// POST `<cognitoDomain>/oauth2/token`. Throws [OsbException]; a refused
/// refresh token gives status 400.
Future<Tokens> requestTokens(
  http.Client client,
  String cognitoDomain,
  Map<String, String> form, {
  DateTime Function() now = DateTime.now,
}) async {
  final res = await send(() => client.post(
        Uri.parse('$cognitoDomain/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: form,
      ));
  if (res.statusCode != 200) {
    throw OsbException('Sign-in failed (${res.statusCode}). Try again.', status: res.statusCode);
  }
  try {
    return Tokens.fromTokenResponse((jsonDecode(res.body) as Map).cast(), now(),
        keepRefreshToken: form['refresh_token']);
  } on Object {
    throw const OsbException('The server sent an unexpected answer.');
  }
}

/// Signs in through [openLogin] and returns the tokens. Throws
/// [SignInCanceled] or [OsbException].
Future<Tokens> signIn({
  required http.Client client,
  required OpenLogin openLogin,
  required String cognitoDomain,
  required String clientId,
  required String redirectUri,
  bool signUp = false,
  bool chooseAccount = false,
  Random? random,
}) async {
  final req = LoginRequest(
      cognitoDomain: cognitoDomain,
      clientId: clientId,
      redirectUri: redirectUri,
      signUp: signUp,
      chooseAccount: chooseAccount,
      random: random);
  final code = req.codeFrom(await openLogin(req.url, Uri.parse(redirectUri).scheme));
  return requestTokens(client, cognitoDomain, {
    'grant_type': 'authorization_code',
    'client_id': clientId,
    'code': code,
    'redirect_uri': redirectUri,
    'code_verifier': req.verifier,
  });
}
