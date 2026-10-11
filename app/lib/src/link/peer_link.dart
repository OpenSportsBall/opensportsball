// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';

import '../protocol/messages.dart';

enum LinkState {
  /// Not started, or Bluetooth is off / not authorized.
  idle,

  /// Main: advertising and waiting for Secondary.
  advertising,

  /// Secondary: looking for Main.
  searching,
  connecting,
  connected,
}

/// A message channel to the other phone. Implementations reconnect on their
/// own after a drop; callers just watch [state].
abstract class PeerLink {
  ValueListenable<LinkState> get state;

  /// Human-readable reason when [state] is idle because of a problem, e.g.
  /// Bluetooth is off.
  ValueListenable<String?> get problem;

  Stream<Msg> get messages;

  Future<void> start();

  /// Sends [msg]. Returns false if there is no connection or the send
  /// failed; callers that need delivery retry until acknowledged.
  Future<bool> send(Msg msg);

  Future<void> dispose();
}
