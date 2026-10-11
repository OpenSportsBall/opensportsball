// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// How this phone is connected, as far as uploading cares.
enum NetworkKind {
  /// No connection.
  offline,

  /// Wi-Fi or Ethernet: fine to upload.
  unmetered,

  /// Mobile data (or anything that isn't Wi-Fi / Ethernet).
  metered,
}

abstract class NetworkMonitor {
  Future<NetworkKind> current();
  Stream<NetworkKind> get changes;
}

NetworkKind classifyConnectivity(List<ConnectivityResult> r) {
  if (r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet)) {
    return NetworkKind.unmetered;
  }
  if (r.isEmpty || r.every((c) => c == ConnectivityResult.none)) return NetworkKind.offline;
  return NetworkKind.metered;
}

class ConnectivityNetworkMonitor implements NetworkMonitor {
  final _connectivity = Connectivity();

  @override
  Future<NetworkKind> current() async =>
      classifyConnectivity(await _connectivity.checkConnectivity());

  @override
  Stream<NetworkKind> get changes => _connectivity.onConnectivityChanged.map(classifyConnectivity);
}
