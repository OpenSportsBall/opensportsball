// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Signs and checks the messages between the two phones with the pairing
/// key from the QR code, so a nearby device that only saw the game id in
/// Main's advertisement can neither send commands nor pose as either phone.
///
/// Sealed layout: `[counter (8, big-endian), tag (16), ...message]`. The tag
/// is HMAC-SHA256 over the direction, the counter and the message,
/// truncated to 16 bytes. The counter is the sender's clock in
/// microseconds, kept strictly increasing; a receiver takes only counters
/// above the last one it accepted and within [kPeerAuthWindow] of its own
/// clock, so captured messages can't be replayed later.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const kPeerKeyBytes = 16;
const _counterBytes = 8, _tagBytes = 16;
const kPeerAuthOverhead = _counterBytes + _tagBytes;

/// How far a counter may be from the receiver's clock. Loose, because the
/// phones' wall clocks are only roughly in step.
const kPeerAuthWindow = Duration(minutes: 10);

enum PeerDirection { toMain, toSecondary }

Uint8List newPeerKey([Random? random]) {
  final r = random ?? Random.secure();
  return Uint8List.fromList(List.generate(kPeerKeyBytes, (_) => r.nextInt(256)));
}

class PeerAuth {
  PeerAuth(Uint8List key, {DateTime Function()? now})
      : _hmac = Hmac(sha256, key),
        _now = now ?? DateTime.now {
    if (key.length != kPeerKeyBytes) throw ArgumentError.value(key.length, 'key', 'must be $kPeerKeyBytes bytes');
  }

  final Hmac _hmac;
  final DateTime Function() _now;
  int _lastSent = 0;
  int _lastAccepted = 0;

  Uint8List seal(Uint8List message, PeerDirection dir) {
    final now = _now().microsecondsSinceEpoch;
    final counter = _lastSent = now > _lastSent ? now : _lastSent + 1;
    final out = Uint8List(kPeerAuthOverhead + message.length);
    ByteData.sublistView(out).setUint64(0, counter);
    out.setRange(_counterBytes, kPeerAuthOverhead, _tag(dir, out.sublist(0, _counterBytes), message));
    out.setRange(kPeerAuthOverhead, out.length, message);
    return out;
  }

  /// The message inside [sealed], or null if it is not from the paired
  /// phone, was sent the other way, or is a replay.
  Uint8List? open(Uint8List sealed, PeerDirection dir) {
    if (sealed.length < kPeerAuthOverhead) return null;
    final message = sealed.sublist(kPeerAuthOverhead);
    final want = _tag(dir, sealed.sublist(0, _counterBytes), message);
    var diff = 0;
    for (var i = 0; i < _tagBytes; i++) {
      diff |= want[i] ^ sealed[_counterBytes + i];
    }
    if (diff != 0) return null;
    final counter = ByteData.sublistView(sealed).getUint64(0);
    if (counter <= _lastAccepted) return null;
    if ((counter - _now().microsecondsSinceEpoch).abs() > kPeerAuthWindow.inMicroseconds) return null;
    _lastAccepted = counter;
    return message;
  }

  List<int> _tag(PeerDirection dir, Uint8List counter, Uint8List message) =>
      _hmac.convert([dir.index, ...counter, ...message]).bytes.sublist(0, _tagBytes);
}
