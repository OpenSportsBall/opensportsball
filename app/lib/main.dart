// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app_services.dart';
import 'src/role.dart';
import 'src/storage/store.dart';
import 'src/ui/account_screen.dart';
import 'src/ui/main_screen.dart';
import 'src/ui/recordings_screen.dart';
import 'src/ui/secondary_screen.dart';
import 'src/ui/settings_screen.dart';
import 'src/ui/uploads_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The phones sit sideways on the mount; one fixed orientation keeps the
  // recordings consistent.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
  runApp(SportsBallVideoApp(store: AppStore.open()));
}

class SportsBallVideoApp extends StatefulWidget {
  const SportsBallVideoApp({
    super.key,
    required this.store,
    this.createServices = createAppServices,
  });

  final Future<AppStore> store;
  final Future<AppServices> Function(AppStore store) createServices;

  @override
  State<SportsBallVideoApp> createState() => _SportsBallVideoAppState();
}

class _SportsBallVideoAppState extends State<SportsBallVideoApp> {
  late final Future<AppServices> _services = widget.store.then(widget.createServices);
  AppServices? _ready;
  late final AppLifecycleListener _lifecycle =
      AppLifecycleListener(onResume: () => _ready?.uploads.kick());

  @override
  void initState() {
    super.initState();
    _lifecycle; // create it
    _services.then<void>((s) => _ready = s, onError: (Object _) {});
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SportsBallVideo',
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.green, useMaterial3: true, brightness: Brightness.dark),
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
        title: const Text('SportsBallVideo'),
        actions: [
          ListenableBuilder(
            listenable: services.account,
            builder: (context, _) => IconButton(
              tooltip: 'Link to account',
              icon: Icon(services.account.linked && !services.account.revoked
                  ? Icons.link
                  : Icons.link_off),
              onPressed: () => _push(context, AccountScreen(account: services.account)),
            ),
          ),
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
            onPressed: () => _push(context, SettingsScreen(store: store)),
          ),
        ],
      ),
      body: Padding(
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
                              ? MainScreen(store: store)
                              : SecondaryScreen(store: store),
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
      ),
    );
  }
}
