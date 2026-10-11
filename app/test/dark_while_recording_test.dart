// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opensportsball/src/ui/dark_while_recording.dart';

import 'fakes.dart';

void main() {
  late FakeCamera camera;
  var taps = 0;

  Widget app({required bool recording, bool enabled = true}) => MaterialApp(
        home: DarkWhileRecording(
          enabled: enabled,
          recording: recording,
          camera: camera,
          status: () => 'REC 00:00:15 · Secondary OK',
          child: Scaffold(body: Center(child: FilledButton(onPressed: () => taps++, child: const Text('Stop')))),
        ),
      );

  setUp(() {
    camera = FakeCamera();
    taps = 0;
  });

  testWidgets('goes dark 15 s into a recording and wakes on tap', (tester) async {
    await tester.pumpWidget(app(recording: true));
    await tester.pump(const Duration(seconds: 14));
    expect(find.text('REC 00:00:15 · Secondary OK'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('REC 00:00:15 · Secondary OK'), findsOneWidget);
    expect(camera.brightness, [0.01]);
    expect(camera.previewPaused, isTrue);

    // The first tap only wakes the screen; it must not reach the button.
    await tester.tap(find.byType(DarkWhileRecording));
    await tester.pump();
    expect(taps, 0);
    expect(camera.brightness, [0.01, null]);
    expect(camera.previewPaused, isFalse);
    await tester.tap(find.text('Stop'));
    expect(taps, 1);

    // ...and darkens again after another 15 s without touches.
    await tester.pump(const Duration(seconds: 15));
    expect(camera.brightness.last, 0.01);
  });

  testWidgets('touching the awake screen pushes the darkening back', (tester) async {
    await tester.pumpWidget(app(recording: true));
    await tester.pump(const Duration(seconds: 10));
    await tester.tap(find.text('Stop'));
    await tester.pump(const Duration(seconds: 10));
    expect(camera.brightness, isEmpty);
    await tester.pump(const Duration(seconds: 5));
    expect(camera.brightness, [0.01]);
  });

  testWidgets('stopping the recording restores the screen', (tester) async {
    await tester.pumpWidget(app(recording: true));
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpWidget(app(recording: false));
    expect(camera.brightness, [0.01, null]);
    expect(camera.previewPaused, isFalse);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('does nothing when the setting is off or not recording', (tester) async {
    await tester.pumpWidget(app(recording: true, enabled: false));
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpWidget(app(recording: false));
    await tester.pump(const Duration(minutes: 1));
    expect(camera.brightness, isEmpty);
  });

  testWidgets('leaving the screen while dark restores brightness', (tester) async {
    await tester.pumpWidget(app(recording: true));
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpWidget(const SizedBox());
    expect(camera.brightness, [0.01, null]);
  });
}
