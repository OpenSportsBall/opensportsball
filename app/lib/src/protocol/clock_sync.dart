// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Estimates the offset between the two phones' clocks from BLE ping/pong
/// round trips. This only seeds the cloud sync, which refines the offset to
/// within a frame by cross-correlating the audio tracks.
library;

import '../model.dart';

class ClockSample {
  const ClockSample({required this.t1, required this.t2, required this.t3});

  /// Secondary clock when the ping was sent.
  final int t1;

  /// Main clock when the ping arrived.
  final int t2;

  /// Secondary clock when the pong arrived.
  final int t3;

  int get rttMs => t3 - t1;

  /// `secondary - main`, assuming the ping and pong took equal time.
  double get offsetMs => (t1 + t3) / 2 - t2;
}

/// Uses the fastest quarter of round trips (at least 3), where queueing
/// delay and asymmetry are smallest, and takes their median offset.
ClockEstimate? estimateClock(List<ClockSample> samples) {
  final valid = samples.where((s) => s.rttMs >= 0).toList()
    ..sort((a, b) => a.rttMs.compareTo(b.rttMs));
  if (valid.isEmpty) return null;
  final keep = (valid.length / 4).ceil().clamp(3, valid.length);
  final offsets = [for (final s in valid.take(keep)) s.offsetMs]..sort();
  final rtts = [for (final s in valid) s.rttMs.toDouble()]..sort();
  return ClockEstimate(
    secondaryOffsetMs: _median(offsets),
    medianRttMs: _median(rtts),
    samples: valid.length,
  );
}

double _median(List<double> sorted) {
  final n = sorted.length;
  return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}
