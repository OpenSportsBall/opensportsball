// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/foundation.dart';

/// Samples battery, thermal state and free storage while recording and
/// appends them to `power.csv` in the recording folder, so field tests show
/// how long a phone lasts and whether heat throttles it. One row at start,
/// one per [every], one at the end.
class PowerLog {
  PowerLog(this.camera, this.file, {this.every = const Duration(minutes: 1)});

  final DualCamera camera;
  final File file;
  final Duration every;

  static const header =
      'elapsed_s,device_ms,battery_pct,charging,thermal,free_storage_mb,note';

  Timer? _timer;
  final _clock = Stopwatch();
  Future<void> _writes = Future.value();

  void start() {
    _clock.start();
    _write(header, sample: false);
    _sample('start');
    _timer = Timer.periodic(every, (_) => _sample(''));
  }

  /// Takes a last sample with [note] (e.g. why recording ended) and stops.
  Future<void> stop([String note = 'stop']) {
    if (_timer == null) return _writes;
    _timer!.cancel();
    _timer = null;
    _sample(note);
    return _writes;
  }

  void _sample(String note) => _write(note, sample: true);

  /// Serialized so rows land in order even if a status call is slow.
  void _write(String text, {required bool sample}) {
    final elapsedS = _clock.elapsed.inSeconds;
    _writes = _writes.then((_) async {
      try {
        var line = text;
        if (sample) {
          final s = await camera.status();
          final note = text.replaceAll(RegExp(r'[,\n\r"]'), ' ');
          line = '$elapsedS,${DateTime.now().millisecondsSinceEpoch},'
              '${s.batteryPercent},${s.charging},${s.thermalState.name},'
              '${s.freeStorageBytes ~/ (1024 * 1024)},$note';
        }
        await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
      } on Object catch (e) {
        // Never let logging get in the way of recording.
        debugPrint('power log: $e');
      }
    });
  }
}
