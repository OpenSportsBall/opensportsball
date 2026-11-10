// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:osb_core/osb_core.dart';
import 'package:test/test.dart';

/// A questions file shaped like `engine.py prepare`'s.
Map<String, Object?> questions() => {
      'schemaVersion': 1,
      'recording': '.',
      'pending': ['pitch', 'kits'],
      'pitch': {
        'round': 2,
        'status': 'pending',
        'background': 'pitch/background.png',
        'overlay': 'pitch/overlay.jpg',
        'panorama': {
          'image': 'background.png',
          'degPerPx': 0.03,
          'yawRange': [-100.0, 100.0],
          'pitchRange': [-2.0, 38.0]
        },
        'fit': {'lengthM': 110.25},
        'lines': [
          [
            [-83.9, 2.7],
            [-83.8, 2.75]
          ]
        ],
        'goals': [
          {
            'side': 'left',
            'valid': true,
            'deg': [
              [-58.8, 1.9],
              [-58.8, -0.3],
              [-53.1, -0.4],
              [-53.1, 1.7]
            ]
          }
        ],
        'points': {
          'left corner flag': {'yaw': -83.908, 'pitch': 2.702}
        },
        'approveAllowed': false,
        'problem': 'mark the pitch first',
      },
      'kits': {
        'round': 1,
        'status': 'pending',
        'k': 8,
        'splitAllowed': true,
        'groups': [
          {
            'component': 0,
            'people': 561,
            'perMoment': 6.9,
            'proposed': 'A',
            'crops': [
              {
                'id': 'c0_00',
                'image': 'engine/crops/kits1/c0_00.jpg',
                'frame': 'f',
                'box': [1, 2, 3, 4]
              }
            ]
          }
        ]
      },
      'futureField': {'ignored': true},
    };

void main() {
  test('reads questions, and maps panorama degrees to pixels and back', () {
    final q = EngineQuestions.fromJson(questions());
    expect(q.pending, ['pitch', 'kits']);
    final p = q.pitch!;
    expect(p.pending, isTrue);
    expect(p.approveAllowed, isFalse);
    expect(p.points['left corner flag']!.yaw, -83.908);
    expect(p.goals.single, hasLength(4));
    final px = p.panorama!.toPx((yaw: -100.0, pitch: 38.0));
    expect(px.x, closeTo(0, 1e-9));
    expect(px.y, closeTo(p.panorama!.height, 1e-9));
    final back = p.panorama!.toDeg(3000, 600);
    expect(back.yaw, closeTo(-10, 1e-9));
    expect(back.pitch, closeTo(16, 1e-9));
    expect(q.kits!.groups.single.crops.single.id, 'c0_00');
  });

  test('writes answers the engine schema accepts', () async {
    final dir = await Directory.systemTemp.createTemp('osb_ans');
    addTearDown(() => dir.delete(recursive: true));
    final a = EngineAnswers()
      ..markPitch(
          2,
          {
            'left corner flag': const MovedPoint((yaw: -83.12345, pitch: 2.5)),
            'centre spot': const SkippedPoint(),
            'x': const FromFitPoint()
          },
          share: true)
      ..answerKits(1,
          tapped: {
            0: {'c0_03', 'c0_00'},
            1: {}
          },
          merge: [
            {3, 2}
          ],
          notKit: {7},
          share: false)
      ..answerCameras(1, mainLeft: false);
    await a.write(dir);
    final j = jsonDecode(await EngineAnswers.fileIn(dir).readAsString()) as Map;
    expect(j['pitch'], {
      'round': 2,
      'points': {
        'left corner flag': {'yaw': -83.123, 'pitch': 2.5},
        'centre spot': {'skipped': true},
        'x': {'fromFit': true},
      },
      'share': true,
    });
    expect(j['kits'], {
      'round': 1,
      'tapped': {
        '0': ['c0_00', 'c0_03']
      },
      'merge': [
        [2, 3]
      ],
      'notKit': [7],
      'share': false,
    });
    expect(j['cameras'], {'round': 1, 'leftPhone': 'secondary'});
    // Read back and changed: the other answers stay.
    final again = await EngineAnswers.read(dir);
    again.approvePitch(3, share: true);
    expect(again.toJson()['kits'], j['kits']);
    expect(again.toJson()['pitch'], {'round': 3, 'approve': true, 'share': true});
  });

  test('runs the engine, reads its events, and stops it with SIGINT', () async {
    final dir = await Directory.systemTemp.createTemp('osb_eng');
    addTearDown(() => dir.delete(recursive: true));
    final fake = File('${dir.path}/fake-engine')..writeAsStringSync('''#!/bin/sh
trap 'echo "{\\"event\\":\\"stopped\\",\\"message\\":\\"stopped\\"}"; exit 130' INT
echo '{"event":"step","step":"sync","status":"started"}'
echo 'a stray print'
echo "args: \$*" >&2
echo '{"event":"progress","stage":"ball","fraction":0.25,"etaS":3600,"newField":1}'
[ "\$1" = run ] && { while true; do sleep 0.1; done; }
echo '{"event":"needs_answers","pending":["pitch"],"questions":"engine/questions.json"}'
exit 3
''');
    await Process.run('chmod', ['+x', fake.path]);
    final cmd = EngineCommand.packaged(fake.path);

    final prep = await EngineRun.start(cmd, ['prepare', 'job.json']);
    final events = await prep.events.toList();
    expect(events.map((e) => e.event), ['step', 'progress', 'needs_answers']);
    expect(events[1].fraction, 0.25);
    expect(events[1].etaS, 3600);
    expect(events[2].pending, ['pitch']);
    expect(await prep.exitCode, EngineExit.needsAnswers);
    expect(prep.stderrTail, ['args: prepare job.json']);

    final run = await EngineRun.start(cmd, ['run', 'job.json']);
    final got = <String>[];
    final done = run.events.listen((e) => got.add(e.event)).asFuture<void>();
    while (!got.contains('progress')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    run.stop();
    expect(await run.exitCode, EngineExit.stopped);
    await done;
    expect(got.last, 'stopped');
  });

  test('a job names the recording folder and the output height', () {
    expect(engineJob('/x/rec', height: 1440, maxChunks: 1), {
      'schemaVersion': 1,
      'recording': '/x/rec',
      'output': {'height': 1440},
      'options': {'maxChunks': 1},
    });
  });
}
