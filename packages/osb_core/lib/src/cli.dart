// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// The `osb` command: what the Mac app does before the engine takes over
/// (sign in, list games, download a recording), for a script or a model
/// working for the user (docs/MAC-APP-PLAN.md, "Using it without the GUI").
///
///     osb status
///     osb sign-in [--site https://...] [--no-browser]
///     osb sign-out
///     osb games
///     osb game <game id>
///     osb download <game id> [--recording <id>] [--folder <work folder>] [--max-segments N]
///
/// Every line on stdout is one JSON object with an `event`, like the
/// engine's. Exit codes: 0 done; 2 a bad command, or a game that isn't
/// there or isn't ready; 3 not signed in (run `osb sign-in`); 4 the server
/// or the network failed, or a file arrived damaged; 130 stopped.
///
/// Signing in happens in the person's own browser; the command only waits
/// for it. A game goes in the folder the app would put it in, with a
/// `job.json` beside the footage for `osb-engine prepare`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'download.dart';
import 'engine.dart';
import 'layout.dart';
import 'loopback_login.dart';
import 'sign_in.dart';
import 'site.dart';
import 'token_store_file.dart';

const exitOk = 0, exitBadInput = 2, exitSignedOut = 3, exitFailed = 4, exitStopped = 130;

class _Fail implements Exception {
  const _Fail(this.code, this.message, this.exitCode);
  final String code;
  final String message;
  final int exitCode;
}

const _usage = 'usage: osb status | sign-in [--site URL] [--no-browser] | sign-out | games | game <game id> | '
    'download <game id> [--recording ID] [--folder DIR] [--max-segments N]';

/// What the command needs from the computer, replaceable in tests.
class CliHost {
  CliHost({
    http.Client? client,
    TokenStore? store,
    StringSink? out,
    Map<String, String>? environment,
    this.openBrowser = openInBrowser,
    this.loginPorts = loopbackLoginPorts,
    this.loginTimeout = const Duration(minutes: 10),
    this.progressEvery = const Duration(seconds: 5),
    this.stop,
  })  : client = client ?? http.Client(),
        environment = environment ?? Platform.environment,
        out = out ?? stdout {
    this.store = store ?? FileTokenStore(defaultSessionFile(this.environment));
  }

  final http.Client client;
  late final TokenStore store;
  final StringSink out;
  final Map<String, String> environment;
  final Future<bool> Function(Uri) openBrowser;
  final List<int> loginPorts;
  final Duration loginTimeout;
  final Duration progressEvery;

  /// Completes when the person stops the command (Ctrl-C).
  final Future<void>? stop;

  void emit(String event, [Map<String, Object?> fields = const {}]) =>
      out.writeln(jsonEncode({'event': event, 'at': DateTime.now().toUtc().toIso8601String(), ...fields}));
}

/// Runs one `osb` command; returns its exit code.
Future<int> runCli(List<String> args, [CliHost? host]) async {
  final h = host ?? CliHost();
  try {
    final a = _Args.parse(args);
    switch (a.command) {
      case 'status':
        return await _status(h);
      case 'sign-in':
        return await _signIn(h, a);
      case 'sign-out':
        await h.store.delete();
        h.emit('signed_out');
        return exitOk;
      case 'games':
        return await _games(h);
      case 'game':
        return await _game(h, a);
      case 'download':
        return await _download(h, a);
      default:
        throw const _Fail('bad_command', _usage, exitBadInput);
    }
  } on _Fail catch (f) {
    h.emit('error', {'code': f.code, 'message': f.message});
    return f.exitCode;
  } on SignedOut {
    h.emit('error', {'code': 'signed_out', 'message': 'Not signed in (or the sign-in has ended). Run: osb sign-in'});
    return exitSignedOut;
  } on DownloadStopped {
    h.emit('stopped', {'message': 'stopped; run the same command to carry on'});
    return exitStopped;
  } on FootageCorrupt catch (e) {
    h.emit('error', {'code': 'footage_corrupt', 'message': e.toString()});
    return exitFailed;
  } on OsbException catch (e) {
    h.emit('error', {'code': e.offline ? 'offline' : 'server', 'message': e.message});
    return exitFailed;
  }
}

class _Args {
  _Args(this.command, this.positional, this.options);
  final String command;
  final List<String> positional;
  final Map<String, String?> options;

  static const _takesValue = {'--site', '--recording', '--folder', '--max-segments'};
  static const _flags = {'--no-browser'};

  static _Args parse(List<String> args) {
    if (args.isEmpty) throw const _Fail('bad_command', _usage, exitBadInput);
    final positional = <String>[];
    final options = <String, String?>{};
    for (var i = 1; i < args.length; i++) {
      final x = args[i];
      if (_takesValue.contains(x)) {
        if (i + 1 >= args.length) throw _Fail('bad_command', '$x needs a value', exitBadInput);
        options[x] = args[++i];
      } else if (_flags.contains(x)) {
        options[x] = null;
      } else if (x.startsWith('--')) {
        throw _Fail('bad_command', 'unknown option $x. $_usage', exitBadInput);
      } else {
        positional.add(x);
      }
    }
    return _Args(args[0], positional, options);
  }

  String one(String what) {
    if (positional.length != 1) throw _Fail('bad_command', '$command takes $what. $_usage', exitBadInput);
    return positional.single;
  }
}

Future<Session> _session(CliHost h) async {
  final s = await Session.restore(h.store, h.client);
  if (s == null) throw const SignedOut();
  return s;
}

Future<int> _status(CliHost h) async {
  final s = await Session.restore(h.store, h.client);
  h.emit('status', {
    'signedIn': s != null,
    if (s != null) 'site': s.config.siteUrl,
    if (s?.email != null) 'email': s!.email,
    'workFolder': defaultWorkFolder(h.environment),
    'next': s == null ? 'osb sign-in' : 'osb games',
  });
  return exitOk;
}

Future<int> _signIn(CliHost h, _Args a) async {
  final typed = a.options['--site'] ?? h.environment['OSB_SITE'] ?? defaultSiteUrl;
  final site = normalizeSiteUrl(typed);
  if (site == null) {
    throw _Fail('bad_site', '$typed isn\'t a website address (it must start with https://)', exitBadInput);
  }
  final config = await loadSiteConfig(h.client, site);
  final clientId = config.desktopClientId;
  if (clientId == null) {
    throw _Fail('no_desktop_sign_in', '$site does not support signing in from a computer yet', exitFailed);
  }
  final login = await LoopbackLogin.bind(ports: h.loginPorts);
  try {
    final tokens = await signIn(
      client: h.client,
      cognitoDomain: config.cognitoDomain,
      clientId: clientId,
      redirectUri: login.redirectUri,
      // The browser may be signed in as someone else: always show the form.
      chooseAccount: true,
      openLogin: (url, _) async {
        final opened = a.options.containsKey('--no-browser') ? false : await h.openBrowser(url);
        h.emit('sign_in', {
          'url': url.toString(),
          'browserOpened': opened,
          'message': opened
              ? 'Sign in on the page that opened in the browser. This command waits for it.'
              : 'Open this address in a browser on this computer and sign in. This command waits for it.',
        });
        final stopped = h.stop;
        if (stopped == null) return login.wait(timeout: h.loginTimeout);
        // Ctrl-C while waiting for the browser.
        return Future.any([
          login.wait(timeout: h.loginTimeout),
          stopped.then<String>((_) => throw const DownloadStopped()),
        ]);
      },
    );
    final s = Session(config: config, tokens: tokens, clientId: clientId, client: h.client, store: h.store);
    await s.save();
    h.emit('signed_in', {'site': site, if (s.email != null) 'email': s.email, 'next': 'osb games'});
    return exitOk;
  } finally {
    await login.close();
  }
}

/// [path] as one word for a shell.
String _quoted(String path) =>
    RegExp(r'^[A-Za-z0-9_./:@%+=-]+$').hasMatch(path) ? path : "'${path.replaceAll("'", "'\\''")}'";

Map<String, Object?> _summary(GameSummary g) => {
      'gameId': g.gameId,
      'when': g.when.toUtc().toIso8601String(),
      'recordings': g.recordingCount,
      'status': g.status,
    };

Future<int> _games(CliHost h) async {
  final games = await (await _session(h)).games();
  h.emit('games', {
    'games': [for (final g in games) _summary(g)],
    'next': 'osb download <gameId> (a game whose status is ready)',
  });
  return exitOk;
}

/// The one game [typed] names: its id, or the start of it.
Future<GameSummary> _find(Session s, String typed) async {
  final hits = [
    for (final g in await s.games())
      if (g.gameId.startsWith(typed)) g
  ];
  if (hits.isEmpty) throw _Fail('no_such_game', 'no game $typed in this account (osb games lists them)', exitBadInput);
  if (hits.length > 1) {
    throw _Fail('no_such_game', '$typed is the start of ${hits.length} games: give more of the id', exitBadInput);
  }
  return hits.single;
}

Future<int> _game(CliHost h, _Args a) async {
  final typed = a.one('one game id');
  final s = await _session(h);
  final summary = await _find(s, typed);
  final g = await s.game(summary.gameId);
  h.emit('game', {
    ..._summary(summary),
    'recordings': [
      for (final r in g.recordings)
        {
          'recordingId': r.recordingId,
          'status': r.status,
          'ready': r.ready,
          'bytes': r.expectedBytes,
          'phones': [
            for (final d in r.devices)
              {'role': d.role, 'model': d.model, 'bytes': d.expectedBytes, 'uploadedBytes': d.uploadedBytes}
          ],
        }
    ],
  });
  return exitOk;
}

Future<int> _download(CliHost h, _Args a) async {
  final typed = a.one('one game id');
  final maxSegments = a.options['--max-segments'] == null ? null : int.tryParse(a.options['--max-segments']!);
  if (a.options['--max-segments'] != null && (maxSegments == null || maxSegments < 1)) {
    throw const _Fail('bad_command', '--max-segments takes a whole number, 1 or more', exitBadInput);
  }
  final s = await _session(h);
  final summary = await _find(s, typed);
  final g = await s.game(summary.gameId);
  final want = a.options['--recording'];
  final ready = [
    for (final r in g.recordings)
      if (r.ready && (want == null || r.recordingId.startsWith(want))) r
  ];
  if (ready.isEmpty) {
    throw _Fail(
        'not_ready',
        g.recordings.isEmpty
            ? 'this game has no recordings'
            : want != null && !g.recordings.any((r) => r.recordingId.startsWith(want))
                ? 'this game has no recording $want (osb game ${summary.gameId} lists them)'
                : 'still uploading from the phones: it can be downloaded once both have finished',
        exitBadInput);
  }
  final rec = ready.first;
  final work = a.options['--folder'] ?? defaultWorkFolder(h.environment);
  final folder =
      Directory(recordingFolder(work, summary, rec.recordingId, onlyRecording: g.recordings.length == 1)).absolute;
  final job = File('${folder.path}/job.json');
  Map<String, Object?> done() => {
        'recording': folder.path,
        'job': job.path,
        'next': 'osb-engine prepare ${_quoted(job.path)}',
      };
  Future<void> writeJob() async {
    // The app's job, if it made one, stays as it is (its output size, its options).
    if (!await job.exists()) await job.writeAsString(jsonEncode(engineJob(folder.path)));
  }

  if (await FootageDownloader.isComplete(folder)) {
    await writeJob();
    h.emit('done', {...done(), 'alreadyDownloaded': true});
    return exitOk;
  }
  await folder.create(recursive: true);
  final dl = FootageDownloader(
    folder: folder,
    client: h.client,
    maxSegments: maxSegments,
    links: () => s.downloads(summary.gameId, rec.recordingId),
  );
  unawaited(h.stop?.then((_) => dl.stop()));
  h.emit('download',
      {'gameId': summary.gameId, 'recordingId': rec.recordingId, 'recording': folder.path, 'bytes': rec.expectedBytes});
  var last = DateTime.fromMillisecondsSinceEpoch(0);
  var lastFiles = -1;
  await dl.run(onProgress: (p) {
    final now = DateTime.now();
    if (p.filesDone == lastFiles && now.difference(last) < h.progressEvery) return;
    last = now;
    lastFiles = p.filesDone;
    final rate = p.bytesPerSecond;
    h.emit('progress', {
      'stage': 'download',
      'fraction': double.parse(p.fraction.toStringAsFixed(4)),
      'doneBytes': p.doneBytes,
      'totalBytes': p.totalBytes,
      'filesDone': p.filesDone,
      'files': p.files,
      'etaS': rate == null || rate <= 0 ? null : ((p.totalBytes - p.doneBytes) / rate).round(),
    });
  });
  await writeJob();
  h.emit('done', done());
  return exitOk;
}
