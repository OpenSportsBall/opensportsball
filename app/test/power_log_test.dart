// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sportsballvideo/src/session/power_log.dart';

import 'fakes.dart';

void main() {
  test('logs a header, a start row, periodic rows and an end row', () async {
    final dir = await Directory.systemTemp.createTemp('sbv_power');
    final file = File('${dir.path}/power.csv');
    final log = PowerLog(FakeCamera(), file, every: const Duration(milliseconds: 30))..start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await log.stop('io_error: low, storage');

    final lines = file.readAsLinesSync();
    expect(lines.first, PowerLog.header);
    final rows = [for (final l in lines.skip(1)) l.split(',')];
    expect(rows.length, greaterThanOrEqualTo(4), reason: 'start, 2+ samples, end');
    expect(rows.every((r) => r.length == 7), isTrue, reason: 'notes cannot add columns');
    expect(rows.first[6], 'start');
    expect(rows.last[6], 'io_error: low  storage');
    expect(rows.first.sublist(2, 6), ['80', 'false', 'nominal', '51200']);

    // A second stop does nothing.
    await log.stop();
    expect(file.readAsLinesSync().length, lines.length);
  });
}
