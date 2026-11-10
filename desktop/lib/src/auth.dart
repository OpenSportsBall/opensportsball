// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Signing in on the Mac: Cognito managed login in the system's sign-in
/// sheet (client `desktopClientId`, docs/API.md "Signing in from the Mac
/// app"), and the session kept in the Keychain.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:osb_core/osb_core.dart';

import 'services.dart';

/// Where managed login returns to (infra's `DESKTOP_LOGIN_CALLBACK`).
const desktopLoginCallback = 'opensportsball://desktop-auth';

Future<String> _systemSheet(Uri url, String callbackScheme) async {
  try {
    return await FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackScheme,
      // Shares the browser's session: already signed in on the website,
      // the app signs in with a click (macOS asks once). After signing out
      // here, the next sign-in asks for the account again (chooseAccount).
      options: const FlutterWebAuth2Options(preferEphemeral: false),
    );
  } on PlatformException catch (e) {
    if (e.code == 'CANCELED') throw const SignInCanceled();
    throw OsbException('Could not open the sign-in page (${e.message ?? e.code}).');
  }
}

class AuthController extends ChangeNotifier {
  AuthController({required this.client, required this.store, OpenLogin? openLogin, this.session, this.settings})
    : _openLogin = openLogin ?? _systemSheet,
      restored = session != null;

  final http.Client client;
  final TokenStore store;
  final OpenLogin _openLogin;

  /// Remembers a sign-out across launches (`chooseAccount`).
  final Settings? settings;

  Session? session;

  /// The Keychain has been read (until then there's nothing to show).
  bool restored;
  bool busy = false;
  String? error;

  Future<void> restore() async {
    if (restored) return;
    session = await Session.restore(store, client);
    restored = true;
    notifyListeners();
  }

  Future<void> signInAt(String typedSite, {bool signUp = false}) async {
    final site = normalizeSiteUrl(typedSite);
    if (site == null) {
      error = 'That isn\'t a website address (it must start with https://).';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final config = await loadSiteConfig(client, site);
      final clientId = config.desktopClientId;
      if (clientId == null) {
        throw OsbException('$site does not support the Mac app yet (no desktop sign-in).');
      }
      final tokens = await signIn(
        client: client,
        openLogin: _openLogin,
        cognitoDomain: config.cognitoDomain,
        clientId: clientId,
        redirectUri: desktopLoginCallback,
        signUp: signUp,
        chooseAccount: settings?.chooseAccount ?? false,
      );
      await settings?.set('chooseAccount', null);
      final s = Session(config: config, tokens: tokens, clientId: clientId, client: client, store: store);
      await s.save();
      session = s;
    } on SignInCanceled {
      // nothing to say
    } on OsbException catch (e) {
      error = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Signs out here (the session's tokens are forgotten; nothing on the
  /// server changes).
  Future<void> signOut() async {
    await session?.signOut();
    // The browser may still be signed in: ask for the account next time.
    await settings?.set('chooseAccount', true);
    session = null;
    notifyListeners();
  }

  /// The server ended the session: back to the sign-in screen.
  void signedOut() {
    if (session == null) return;
    session = null;
    error = 'Signed out. Sign in again to carry on.';
    store.delete();
    notifyListeners();
  }
}
