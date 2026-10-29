// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math' as math;

import 'package:dual_camera/dual_camera.dart';

import '../model.dart';

/// Why [SettleWatcher] wants camera settings locked now.
enum LockReason {
  /// The phone has been still, the way it sits on the mount, for a while.
  settled,

  /// Recording has run [SettleWatcher.timeout] without the phone ever
  /// settling (held all game, say): lock anyway rather than refocus all
  /// game.
  timeout,
}

/// Decides when to lock white balance and focus during a recording. People
/// start recording before the phone is on the mount, or before the tripod
/// is raised, so locking when recording starts can lock on the grass at
/// their feet. Instead the recorder polls [DualCamera.motion] about once a
/// second and feeds each window here; this says when the phone has come to
/// rest in a mount-like pose, and again whenever it is moved after that.
///
/// The same rules run on both platforms. All thresholds are in one place
/// so they can be tuned from what recordings report.
class SettleWatcher {
  SettleWatcher({
    this.settleWindows = 5,
    this.timeout = const Duration(minutes: 3),
  });

  /// Consecutive still, mount-like windows (about a second each) before
  /// locking.
  final int settleWindows;

  /// Lock once anyway if nothing has been locked this long into recording.
  final Duration timeout;

  /// A window is still below these. A phone on a tripod in a breeze turns
  /// well under 1 deg/s; a hand holding one turns several.
  static const stillRotationDegPerS = 3.0;
  static const stillAccelerationG = 0.05;

  /// ... and if up moved less than this since the previous window (for
  /// phones without a gyroscope, and slow drifts the gyroscope misses).
  static const stillTiltDeg = 0.5;

  /// A mount-like pose: landscape either way up, roughly level, looking
  /// about at the horizon or down at the field. Rules out a phone lying
  /// flat, held in portrait, or aimed at the ground.
  static const maxMountRollDeg = 15.0;
  static const minMountPitchDeg = -40.0;
  static const maxMountPitchDeg = 15.0;

  /// After a lock, the phone counts as moved (and gets locked again once it
  /// settles) if up turns this far from where it was at the lock ...
  static const movedTiltDeg = 2.0;

  /// ... or one window shakes this hard: raising the tripod or putting the
  /// phone in the mount, without changing its tilt much.
  static const movedRotationDegPerS = 15.0;
  static const movedAccelerationG = 0.15;

  int _stillRun = 0;
  UpVector? _previousUp;
  UpVector? _lockedUp;
  bool _everLocked = false;
  bool _moved = true;

  /// Whether a lock has happened and the phone hasn't moved since.
  bool get locked => _everLocked && !_moved;

  /// Feeds one window; returns a reason when settings should be locked
  /// now. Call [didLock] once the lock is done.
  LockReason? add(MotionWindow w, Duration sinceStart) {
    final up = w.up;
    final still = up != null && _isStill(w, up);
    final previous = _previousUp;
    _previousUp = up;

    if (_everLocked && !_moved && up != null && _movedSinceLock(w, up)) _moved = true;

    if (!_moved) return null;
    _stillRun = still && previous != null && angleDeg(previous, up) < stillTiltDeg && isMountPose(up)
        ? _stillRun + 1
        : 0;
    if (_stillRun >= settleWindows) return LockReason.settled;
    if (!_everLocked && sinceStart >= timeout) return LockReason.timeout;
    return null;
  }

  /// The lock asked for by [add] has been applied; [up] is where the phone
  /// pointed (the latest window's, if the lock itself had none).
  void didLock(UpVector? up) {
    _everLocked = true;
    _moved = false;
    _stillRun = 0;
    _lockedUp = up ?? _previousUp;
  }

  bool _isStill(MotionWindow w, UpVector up) =>
      (w.maxRotationDegPerS ?? 0) < stillRotationDegPerS &&
      (w.maxAccelerationG ?? 0) < stillAccelerationG;

  bool _movedSinceLock(MotionWindow w, UpVector up) {
    final ref = _lockedUp;
    if (ref != null && angleDeg(ref, up) > movedTiltDeg) return true;
    return (w.maxRotationDegPerS ?? 0) > movedRotationDegPerS ||
        (w.maxAccelerationG ?? 0) > movedAccelerationG;
  }

  static bool isMountPose(UpVector up) {
    final o = MountOrientation.fromUp(up);
    return (o.uprightRotationDeg == 0 || o.uprightRotationDeg == 180) &&
        o.rollDeg.abs() <= maxMountRollDeg &&
        o.pitchDeg >= minMountPitchDeg &&
        o.pitchDeg <= maxMountPitchDeg;
  }

  static double angleDeg(UpVector a, UpVector b) {
    final la = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    final lb = math.sqrt(b.x * b.x + b.y * b.y + b.z * b.z);
    if (la == 0 || lb == 0) return 180;
    final c = ((a.x * b.x + a.y * b.y + a.z * b.z) / (la * lb)).clamp(-1.0, 1.0);
    return math.acos(c) * 180 / math.pi;
  }
}
