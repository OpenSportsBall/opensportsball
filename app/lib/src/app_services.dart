// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:dual_camera/dual_camera.dart';
import 'package:http/http.dart' as http;

import 'storage/store.dart';
import 'upload/account.dart';
import 'upload/background.dart';
import 'upload/network.dart';
import 'upload/upload_service.dart';

/// What the screens share once the store is open.
class AppServices {
  const AppServices({
    required this.store,
    required this.account,
    required this.uploads,
    this.background,
  });
  final AppStore store;
  final AccountManager account;
  final UploadService uploads;

  /// Keeps [uploads] going with the app off screen.
  final BackgroundUploads? background;
}

Future<AppServices> createAppServices(AppStore store) async {
  final client = http.Client();
  final account = AccountManager(store: store, secrets: SecureSecretStore(), client: client);
  await account.load();
  final camera = DualCamera();
  final uploads = UploadService(
    store: store,
    account: account,
    client: client,
    network: ConnectivityNetworkMonitor(),
    keepScreenOn: camera.setKeepScreenOn,
  )..start();
  final background = BackgroundUploads(uploads: uploads)..start();
  // Footage from a recording the app died during would otherwise never
  // upload. Hashing can take a while, so don't hold up startup.
  unawaited(store.recoverInterruptedRecordings().then((n) {
    if (n > 0) uploads.kick();
  }));
  return AppServices(store: store, account: account, uploads: uploads, background: background);
}
