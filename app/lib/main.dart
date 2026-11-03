// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app_services.dart';
import 'src/role.dart';
import 'src/storage/store.dart';
import 'src/ui/brand.dart';
import 'src/ui/main_screen.dart';
import 'src/ui/recordings_screen.dart';
import 'src/ui/secondary_screen.dart';
import 'src/ui/settings_screen.dart';
import 'src/ui/uploads_screen.dart';
import 'src/upload/grant_link.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The phones sit sideways on the mount; one fixed orientation keeps the
  // recordings consistent.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
  // Subscribed before the first frame, so the link that launched the app
  // is not missed.
  runApp(OpenSportsBallApp(store: AppStore.open(), links: AppLinks().uriLinkStream));
}

class OpenSportsBallApp extends StatefulWidget {
  const OpenSportsBallApp({
    super.key,
    required this.store,
    this.createServices = createAppServices,
    this.links,
  });

  final Future<AppStore> store;
  final Future<AppServices> Function(AppStore store) createServices;

  /// Links that opened the app (upload permission links, docs/API.md).
  final Stream<Uri>? links;

  @override
  State<OpenSportsBallApp> createState() => _OpenSportsBallAppState();
}

class _OpenSportsBallAppState extends State<OpenSportsBallApp> {
  late final Future<AppServices> _services = widget.store.then(widget.createServices);
  AppServices? _ready;
  final _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<Uri>? _links;
  late final AppLifecycleListener _lifecycle =
      AppLifecycleListener(onResume: () {
    _ready?.uploads.kick();
    _ready?.background?.resumed();
  });

  @override
  void initState() {
    super.initState();
    _lifecycle; // create it
    _services.then<void>((s) => _ready = s, onError: (Object _) {});
    _links = widget.links?.listen(_onLink, onError: (Object e) => debugPrint('app link: $e'));
  }

  Future<void> _onLink(Uri uri) async {
    if (uri.scheme != 'opensportsball' || uri.host != 'grant') return;
    final s = await _services;
    final r = await openGrantLink(uri.toString(), store: s.store, account: s.account, uploads: s.uploads);
    final context = _navigator.currentContext;
    if (context == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(r.title),
        content: Text(r.message),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'OpenSportsBall',
      theme: buildBrandTheme(Brightness.light),
      darkTheme: buildBrandTheme(Brightness.dark),
      home: FutureBuilder(
        future: _services,
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(body: Center(child: Text('Could not start: ${snap.error}')));
          }
          if (!snap.hasData) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return RolePickerScreen(services: snap.data!);
        },
      ),
    );
  }
}

/// First screen: each phone chooses whether it controls the recording
/// (Main) or follows it (Secondary).
class RolePickerScreen extends StatelessWidget {
  const RolePickerScreen({super.key, required this.services});

  final AppServices services;
  AppStore get store => services.store;

  void _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenSportsBall'),
        actions: [
          IconButton(
            tooltip: 'Uploads',
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: () => _push(
                context, UploadsScreen(uploads: services.uploads, account: services.account)),
          ),
          IconButton(
            tooltip: 'Recordings',
            icon: const Icon(Icons.video_library_outlined),
            onPressed: () => _push(context, RecordingsScreen(
                store: store, account: services.account, uploads: services.uploads)),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _push(context, SettingsScreen(
                store: store, account: services.account, uploads: services.uploads)),
          ),
        ],
      ),
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            for (final role in DeviceRole.values)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton(
                        onPressed: () => _push(
                          context,
                          role == DeviceRole.main
                              ? MainScreen(store: store, account: services.account)
                              : SecondaryScreen(store: store, account: services.account),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(role.label),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(role.description, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
          ],
        ),
      )),
    );
  }
}
