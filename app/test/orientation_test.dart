// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math' as math;

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opensportsball/src/model.dart';

/// Up for a camera whose picture is turned clockwise by [rollDeg] and
/// that looks [pitchDeg] above the horizontal.
UpVector up(double rollDeg, double pitchDeg) {
  final r = rollDeg * math.pi / 180, p = pitchDeg * math.pi / 180;
  return UpVector(math.sin(r) * math.cos(p), math.cos(r) * math.cos(p), -math.sin(p));
}

void main() {
  Map<String, Object?> from(UpVector u) => MountOrientation.fromUp(u).toJson();

  test('upright, looking down at the field', () {
    expect(from(up(0, -12)), {'uprightRotationDeg': 0, 'rollDeg': 0.0, 'pitchDeg': -12.0});
  });

  test('mounted upside down', () {
    expect(from(up(180, -12)), {'uprightRotationDeg': 180, 'rollDeg': 0.0, 'pitchDeg': -12.0});
    expect(from(up(-178, -5)), {'uprightRotationDeg': 180, 'rollDeg': 2.0, 'pitchDeg': -5.0});
    expect(from(up(176.5, 3)), {'uprightRotationDeg': 180, 'rollDeg': -3.5, 'pitchDeg': 3.0});
  });

  test('a slightly crooked mount', () {
    // The horizon falls to the right: the scene is turned clockwise.
    expect(from(up(4.2, 0)), {'uprightRotationDeg': 0, 'rollDeg': 4.2, 'pitchDeg': 0.0});
    expect(from(up(-4.2, 0)), {'uprightRotationDeg': 0, 'rollDeg': -4.2, 'pitchDeg': 0.0});
  });

  test('sideways (portrait) phones', () {
    // Up points to the picture's right: the scene is turned a quarter
    // clockwise, so a quarter counterclockwise (270 clockwise) fixes it.
    expect(MountOrientation.fromUp(up(90, 0)).uprightRotationDeg, 270);
    expect(MountOrientation.fromUp(up(-90, 0)).uprightRotationDeg, 90);
  });

  test('round-trips through JSON', () {
    final o = MountOrientation.fromUp(up(181.3, -20));
    final back = MountOrientation.fromJson(o.toJson());
    expect(back.toJson(), o.toJson());
    expect(back.uprightRotationDeg, 180);
    expect(back.rollDeg, 1.3);
  });
}
