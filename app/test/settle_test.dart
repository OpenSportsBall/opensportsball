// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math' as math;

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opensportsball/src/session/settle.dart';

/// Up for a landscape phone looking [pitchDeg] above the horizontal
/// (negative: down), upside down if [flipped].
UpVector pose(double pitchDeg, {bool flipped = false, double rollDeg = 0}) {
  final p = pitchDeg * math.pi / 180, r = rollDeg * math.pi / 180;
  final y = math.cos(p) * math.cos(r), x = math.cos(p) * math.sin(r);
  return UpVector(flipped ? -x : x, flipped ? -y : y, -math.sin(p));
}

MotionWindow still(UpVector up) =>
    MotionWindow(samples: 50, up: up, maxRotationDegPerS: 0.3, maxAccelerationG: 0.01);

MotionWindow shaking(UpVector up) =>
    MotionWindow(samples: 50, up: up, maxRotationDegPerS: 40, maxAccelerationG: 0.4);

void main() {
  /// Feeds [windows] a second apart; returns (second, reason) for each lock,
  /// telling the watcher every lock happened.
  List<(int, LockReason)> run(SettleWatcher w, Iterable<MotionWindow> windows, {int startS = 0}) {
    final locks = <(int, LockReason)>[];
    var t = startS;
    for (final m in windows) {
      final r = w.add(m, Duration(seconds: t));
      if (r != null) {
        locks.add((t, r));
        w.didLock(m.up);
      }
      t++;
    }
    return locks;
  }

  final mounted = pose(-8);

  test('locks after five still seconds on the mount, not before', () {
    final w = SettleWatcher();
    // Held while walking to the tripod, then on it and still.
    final locks = run(w, [
      for (var i = 0; i < 10; i++) shaking(pose(-30 + i.toDouble())),
      for (var i = 0; i < 8; i++) still(mounted),
    ]);
    // The first still window only sets the reference; five more are needed.
    expect(locks, [(15, LockReason.settled)]);
    expect(w.locked, isTrue);
  });

  test('an upside-down phone on the mount settles too', () {
    final locks = run(SettleWatcher(), [for (var i = 0; i < 7; i++) still(pose(-8, flipped: true))]);
    expect(locks.single.$2, LockReason.settled);
  });

  test('a still phone that is not mounted never locks before the timeout', () {
    for (final up in [
      const UpVector(0, 0, 1), // lying flat, camera down
      pose(-60), // aimed at the ground at someone's feet
      const UpVector(1, 0, 0), // portrait
      pose(-8, rollDeg: 30), // badly tilted
    ]) {
      final w = SettleWatcher();
      expect(run(w, [for (var i = 0; i < 30; i++) still(up)]), isEmpty, reason: '$up');
    }
  });

  test('raising the tripod after a lock locks again once it is still', () {
    final w = SettleWatcher();
    final locks = run(w, [
      for (var i = 0; i < 6; i++) still(mounted), // on the tripod, lowered: lock at 5
      for (var i = 0; i < 3; i++) shaking(mounted), // raising it: same tilt, but shaken
      for (var i = 0; i < 6; i++) still(mounted), // up: lock again
    ]);
    expect(locks.map((l) => l.$1), [5, 13]);
  });

  test('a slow tilt after a lock counts as moved; a breeze does not', () {
    final w = SettleWatcher();
    final locks = run(w, [
      for (var i = 0; i < 6; i++) still(mounted),
      // Wobbling in the wind: small rotations, tilt unchanged.
      for (var i = 0; i < 20; i++)
        MotionWindow(samples: 50, up: pose(-8 + (i.isEven ? 0.2 : -0.2)), maxRotationDegPerS: 2, maxAccelerationG: 0.03),
    ]);
    expect(locks.length, 1);
    // Someone nudges it to look further down, gently.
    final more = run(w, [for (var i = 0; i < 7; i++) still(pose(-12))], startS: 26);
    expect(more.single.$2, LockReason.settled);
  });

  test('times out once if the phone never settles', () {
    final w = SettleWatcher(timeout: const Duration(seconds: 20));
    final locks = run(w, [for (var i = 0; i < 40; i++) shaking(pose(-8 + (i % 3).toDouble()))]);
    expect(locks, [(20, LockReason.timeout)]);
  });

  test('no motion sensors: falls back to the timeout', () {
    final w = SettleWatcher(timeout: const Duration(seconds: 10));
    final locks = run(w, [for (var i = 0; i < 15; i++) const MotionWindow(samples: 0)]);
    expect(locks, [(10, LockReason.timeout)]);
  });

  test('a phone without a gyroscope still settles on tilt alone', () {
    final locks = run(SettleWatcher(), [for (var i = 0; i < 7; i++) MotionWindow(samples: 10, up: mounted)]);
    expect(locks.single.$2, LockReason.settled);
  });
}
