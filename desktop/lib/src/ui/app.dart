// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../auth.dart';
import '../brand.dart';
import '../services.dart';
import 'games_screen.dart';
import 'sign_in_screen.dart';

class OsbDesktopApp extends StatefulWidget {
  const OsbDesktopApp({super.key, required this.auth, required this.settings, required this.client});
  final AuthController auth;
  final Settings settings;
  final http.Client client;

  @override
  State<OsbDesktopApp> createState() => _OsbDesktopAppState();
}

class _OsbDesktopAppState extends State<OsbDesktopApp> {
  final _games = GlobalKey<GamesScreenState>();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Quitting stops the engine cleanly; the same step carries on next time.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _games.currentState?.shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OpenSportsBall',
    debugShowCheckedModeBanner: false,
    theme: buildBrandTheme(Brightness.light),
    darkTheme: buildBrandTheme(Brightness.dark),
    home: ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) {
        final session = widget.auth.session;
        if (session == null) {
          return widget.auth.restored
              ? SignInScreen(auth: widget.auth, settings: widget.settings)
              : const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return GamesScreen(
          key: _games,
          session: session,
          auth: widget.auth,
          settings: widget.settings,
          client: widget.client,
        );
      },
    ),
  );
}
