// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Signing in from a command line: managed login opens in the person's own
/// browser and sends it back to a page on this computer
/// (`http://localhost:<port>/callback`, RFC 8252), where the `osb` command
/// is listening. The command never sees a password.
library;

import 'dart:async';
import 'dart:io';

import 'site.dart';

/// The ports the Desktop sign-in client allows a callback on (infra's
/// `DESKTOP_CLI_LOGIN_PORTS`: Cognito matches the whole URL, port included).
/// The first that is free is used.
const loopbackLoginPorts = [47161, 47162, 47163];

/// One sign-in's listener on this computer.
class LoopbackLogin {
  LoopbackLogin._(this._servers, this.port);

  final List<HttpServer> _servers;
  final int port;

  /// Listens on the first free port of [ports], on this computer only.
  /// Throws [OsbException] when all are taken.
  static Future<LoopbackLogin> bind({List<int> ports = loopbackLoginPorts}) async {
    for (final p in ports) {
      try {
        final v4 = await HttpServer.bind(InternetAddress.loopbackIPv4, p);
        HttpServer? v6;
        try {
          // A browser may reach "localhost" on either.
          v6 = await HttpServer.bind(InternetAddress.loopbackIPv6, v4.port);
        } on SocketException {
          // no IPv6 here, or the port is taken on it
        }
        return LoopbackLogin._([v4, if (v6 != null) v6], v4.port);
      } on SocketException {
        continue;
      }
    }
    throw OsbException('Could not listen for the sign-in on this computer (ports ${ports.join(', ')} are in use).');
  }

  /// Where managed login sends the browser back to.
  String get redirectUri => 'http://localhost:$port/callback';

  /// The URL the browser came back to, once it does. Throws [OsbException]
  /// when nobody signs in within [timeout].
  Future<String> wait({Duration timeout = const Duration(minutes: 10)}) {
    final done = Completer<String>();
    for (final s in _servers) {
      s.listen((req) async {
        final res = req.response;
        if (req.method != 'GET' || req.uri.path != '/callback') {
          res.statusCode = HttpStatus.notFound;
          await res.close();
          return;
        }
        final failed = req.uri.queryParameters['error'] != null || req.uri.queryParameters['code'] == null;
        res.headers.contentType = ContentType.html;
        res.headers.set('Cache-Control', 'no-store');
        res.write('<!doctype html><meta charset="utf-8"><title>OpenSportsBall</title>'
            '<body style="font: 18px system-ui; margin: 4em auto; max-width: 30em">'
            '${failed ? '<p>Sign-in did not finish. Go back to the terminal and try again.</p>' : '<p>Signed in. You can close this tab and go back to the terminal.</p>'}'
            '</body>');
        await res.close();
        if (!done.isCompleted) done.complete('$redirectUri?${req.uri.query}');
      });
    }
    return done.future.timeout(timeout, onTimeout: () {
      throw OsbException('Nobody signed in within ${timeout.inMinutes} minutes. Run it again when ready.');
    });
  }

  Future<void> close() async {
    for (final s in _servers) {
      await s.close(force: true);
    }
  }
}

/// Opens [url] in the person's default browser. False when it couldn't
/// (no desktop session): they open the printed address themselves.
Future<bool> openInBrowser(Uri url) async {
  final cmd = Platform.isMacOS
      ? '/usr/bin/open'
      : Platform.isWindows
          ? 'explorer'
          : 'xdg-open';
  try {
    return (await Process.run(cmd, [url.toString()])).exitCode == 0;
  } on Object {
    return false;
  }
}
