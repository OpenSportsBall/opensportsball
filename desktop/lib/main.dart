// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'src/auth.dart';
import 'src/demo.dart';
import 'src/services.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final client = http.Client();
  // OSB_DEMO_RECORDING: a stand-in server for development (src/demo.dart).
  final demo = demoSession();
  final auth = AuthController(client: client, store: KeychainTokenStore(), session: demo);
  runApp(OsbDesktopApp(auth: auth, settings: settings, client: client));
  await auth.restore();
}
