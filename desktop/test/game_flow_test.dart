// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// A game from the games list to game.mp4, with a stand-in API and footage
/// server and a stand-in engine (fake_engine.py: the real commands, files
/// and progress lines).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:osb_core/osb_core.dart';
import 'package:osb_desktop/src/game_controller.dart';
import 'package:osb_desktop/src/services.dart';

const gameId = '11111111-2222-3333-4444-555555555555';
const recId = '99999999-8888-7777-6666-555555555555';
final seg = Uint8List.fromList(List.generate(5000, (i) => i % 256));

/// What the stand-in API holds of the contributions sent to it.
class Shared {
  /// Contribution id to its name, for those not withdrawn.
  final live = <String, String>{};

  /// Every file that arrived, as `<contribution id>/<path>`.
  final files = <String>{};
  int _n = 0;
}

/// [liveStatus], when given, is asked on every request: a recording that
/// finishes uploading between two looks.
Session fakeServer({String status = 'ready', String Function()? liveStatus, Shared? shared}) {
  final sha = sha256.convert(seg).toString();
  final manifest = {
    'gameId': gameId,
    'devices': [
      {
        'deviceId': 'main',
        'role': 'main',
        'segments': [
          {'index': 0, 'objectKey': 'main/main_000.mp4', 'bytes': seg.length, 'sha256': sha},
        ],
      },
    ],
  };
  Future<http.StreamedResponse> json(Object o) async =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(o))), 200);
  final client = MockClient.streaming((req, body) async {
    final p = req.url.path;
    if (p == '/games/$gameId') {
      return json({
        'gameId': gameId,
        'recordings': [
          {
            'recordingId': recId,
            'status': liveStatus?.call() ?? status,
            'devices': [
              {'deviceId': 'main', 'role': 'main', 'model': 'Pixel', 'expectedBytes': seg.length},
            ],
          },
        ],
      });
    }
    if (p.endsWith('/downloads')) {
      return json({
        'status': liveStatus?.call() ?? status,
        'expiresAt': DateTime.now().add(const Duration(hours: 12)).toUtc().toIso8601String(),
        'manifestUrl': 'https://cdn.test/manifest.json',
        'files': [
          {
            'deviceId': 'main',
            'fileName': 'main_000.mp4',
            'bytes': seg.length,
            'sha256': sha,
            'url': 'https://cdn.test/main/main_000.mp4',
          },
        ],
      });
    }
    if (shared != null && req.url.host == 's3.test') {
      shared.files.add(p.substring(1));
      return http.StreamedResponse(const Stream.empty(), 200);
    }
    if (shared != null && p == '/contributions' && req.method == 'POST') {
      final b = jsonDecode(await body.bytesToString()) as Map;
      expect(b['consentVersion'], 'share-v1');
      expect(b['recordingId'], recId);
      final doc = b['contribution'] as Map;
      final id = 'c${++shared._n}';
      shared.live[id] = doc['name'] as String;
      return json({
        'contributionId': id,
        'status': 'uploading',
        'uploads': [
          for (final f in (doc['files'] as List).cast<Map>())
            {'path': f['path'], 'url': 'https://s3.test/$id/${f['path']}', 'headers': <String, String>{}},
        ],
      });
    }
    if (shared != null && p.endsWith('/complete')) return json({'status': 'complete'});
    if (shared != null && req.method == 'DELETE' && p.startsWith('/contributions/')) {
      shared.live.remove(p.split('/').last);
      return http.StreamedResponse(const Stream.empty(), 204);
    }
    if (p == '/manifest.json') return json(manifest);
    if (p == '/main/main_000.mp4') return http.StreamedResponse(Stream.value(seg), 200);
    return http.StreamedResponse(const Stream.empty(), 404);
  });
  return Session(
    config: const SiteConfig(
      siteUrl: 'https://x.test',
      apiUrl: 'https://api.x.test',
      cognitoDomain: 'https://l.x.test',
    ),
    clientId: 'c',
    client: client,
    store: MemoryTokenStore(),
    tokens: Tokens(accessToken: 'a', expiresAt: DateTime(2100)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory work;
  late Settings settings;
  final summary = GameSummary(
    gameId: gameId,
    createdAt: DateTime(2026, 10, 15, 9, 23),
    recordedAt: DateTime(2026, 10, 15, 9, 23),
  );

  setUp(() async {
    work = await Directory.systemTemp.createTemp('osb_flow');
    settings = Settings.inMemory(File('${work.path}/settings.json'), {
      'workFolder': '${work.path}/games',
      'enginePath': File('test/fake_engine.py').absolute.path,
    });
  });
  tearDown(() => work.delete(recursive: true));

  GameController controller(Session s) =>
      GameController(summary: summary, session: s, settings: settings, onSignedOut: () {});

  test('download, prepare, the checks, the run, and picking up where it was after a restart', () async {
    final ctl = controller(fakeServer());
    await ctl.open();
    expect(ctl.phase, Phase.needsDownload);
    expect(ctl.folder!.path, endsWith('/games/2026-10-15 09.23 11111111'));

    await ctl.startDownload(); // prepares by itself
    expect(ctl.error, isNull);
    expect(File('${ctl.folder!.path}/main/main_000.mp4').readAsBytesSync(), seg);
    expect(ctl.phase, Phase.questions);
    expect(ctl.questions!.pending, ['pitch']);
    // The last step's name, start and log, for the step clock.
    expect(ctl.step, 'pitch');
    expect(ctl.stepStartedAt, isNotNull);
    expect(ctl.stepLog, '${ctl.folder!.path}/engine/logs/pitch.log');

    await ctl.answer((a) => a.approvePitch(ctl.questions!.pitch!.round, share: true));
    expect(ctl.questions!.pending, isEmpty); // the teams aren't asked about
    expect(ctl.phase, Phase.readyToRun);

    // The engine got the job and every answer.
    final calls = [
      for (final l in File('${ctl.folder!.path}/engine/calls.jsonl').readAsLinesSync()) jsonDecode(l) as Map,
    ];
    final last = calls.lastWhere((c) => c['cmd'] == 'prepare');
    expect(last['answers'], {
      'pitch': {'round': 1, 'approve': true, 'share': true},
    });
    expect((last['job'] as Map)['recording'], ctl.folder!.path);

    final fractions = <double>[];
    int? lowAfter;
    ctl.addListener(() {
      if (ctl.fraction != null) fractions.add(ctl.fraction!);
      if (ctl.ballLow) lowAfter ??= ctl.ball!.byChunk.length;
    });
    await ctl.run();
    expect(ctl.phase, Phase.done);
    expect(ctl.output, endsWith('fullgame/game.mp4'));
    expect(fractions, containsAllInOrder([0.25, 0.5, 0.75]));
    expect(File('${ctl.folder!.path}/engine/app-run.pid').existsSync(), isFalse);

    // From its second chunk the engine said it doesn't know this ball.
    expect(lowAfter, 2);
    expect(ctl.ballLow, isTrue);
    expect(ctl.ball!.byChunk, [31, 2, 0, 1]);

    // A new launch finds it done, from the folder alone: the ball and each segment too.
    final again = controller(fakeServer());
    await again.open();
    expect(again.phase, Phase.done);
    expect(again.ballLow, isTrue);
    expect(again.chunkDetails, hasLength(4));
    expect(again.chunkDetails[1].ballAimPct, 2);
    expect(again.chunkDetails[1].follow.status, 'done');
    expect(again.chunkDetails[1].startS, 600);

    // Ball labels: the engine picks the frames, the labels go back to it, and a
    // set begun is carried on with, not made again.
    final set = await again.ballSet();
    expect(set.frames.map((f) => f.id), ['b0', 'b1', 'b2']);
    expect(File(set.frames.first.image).existsSync(), isTrue);
    expect(set.frames.first.suggestions.single.x, 1000);
    var now = await again.saveBallLabels(set, {'b0': const BallAt(1000, 500), 'b2': const NoBall()});
    expect(now.labelled, 2);
    expect(now.complete, isFalse);
    expect((await again.ballSet()).name, 'ball-1');
    expect((await again.ballSet()).labels['b0'], isA<BallAt>());
    now = await again.saveBallLabels(now, {'b1': const BallUnsure()});
    expect(now.complete, isTrue);
    final stored = jsonDecode(File('${now.folder.path}/answers.json').readAsStringSync()) as Map;
    expect(stored, {
      'b0': {'status': 'ball', 'x': 1000.0, 'y': 500.0},
      'b2': {'status': 'none'},
      'b1': {'status': 'unsure'},
    });
    // Sharing isn't agreed: nothing was listed for sending, nothing sent.
    await again.sendAgreed();
    expect(Directory('${again.folder!.path}/engine/share').existsSync(), isFalse);
    expect(again.sharedNames, isEmpty);
  });

  test(
    'what was agreed is sent: the pitch map by its switch, the ball marks; and withdrawn',
    () async {
      final shared = Shared();
      final ctl = controller(fakeServer(shared: shared));
      await ctl.open();
      await ctl.startDownload();
      await ctl.answer((a) => a.approvePitch(ctl.questions!.pitch!.round, share: true));
      expect(ctl.phase, Phase.readyToRun);

      // The checks are answered, but the sharing wording isn't agreed: nothing goes.
      await ctl.sendAgreed();
      expect(shared.live, isEmpty);
      expect(File('${ctl.folder!.path}/engine/share/pitch.json').existsSync(), isFalse);

      // Agreed: the pitch map goes.
      await settings.setSharingAgreed(true);
      await ctl.sendAgreed();
      expect(ctl.shareError, isNull);
      expect(shared.live, {'c1': 'pitch'});
      expect(shared.files, {'c1/pitch/pitch.json', 'c1/pitch/background.png'});
      expect(ctl.sharedNames, ['pitch']);

      // The run sends nothing new; ball marks go when they are saved, and
      // again (the older copy withdrawn) when more are added.
      await ctl.run();
      await ctl.sendAgreed();
      expect(shared.live, {'c1': 'pitch'});
      final set = await ctl.ballSet();
      var now = await ctl.saveBallLabels(set, {'b0': const BallAt(1000, 500)});
      await ctl.sendAgreed();
      expect(shared.live, {'c1': 'pitch', 'c2': 'ball-1'});
      expect(shared.files, contains('c2/engine/labels/ball-1/images/b0.jpg'));
      expect(shared.files, isNot(contains('c2/engine/labels/ball-1/images/b1.jpg'))); // not marked, not sent
      now = await ctl.saveBallLabels(now, {'b1': const NoBall()});
      await ctl.sendAgreed();
      expect(shared.live, {'c1': 'pitch', 'c3': 'ball-1'});
      expect(ctl.sharedNames, ['ball-1', 'pitch']);

      // A new launch knows what was sent, and sends nothing twice.
      final again = controller(fakeServer(shared: shared));
      await again.open();
      await again.sendAgreed();
      expect(again.sharedNames, ['ball-1', 'pitch']);
      expect(shared.live.keys, ['c1', 'c3']);

      // Withdrawn: deleted from the project, and nothing more goes from this game.
      await again.withdrawShared();
      expect(shared.live, isEmpty);
      expect(again.sharedNames, isEmpty);
      expect(again.shareStopped, isTrue);
      await again.saveBallLabels(now, {'b2': const BallUnsure()});
      await again.sendAgreed();
      expect(shared.live, isEmpty);
      await again.shareAgain();
      expect(shared.live.values, unorderedEquals(['pitch', 'ball-1']));
    },
  );

  test('the YouTube copy: made beside game.mp4, and alone for a game already done', () async {
    final ctl = controller(fakeServer());
    await ctl.open();
    await ctl.startDownload();
    await ctl.answer((a) => a.approvePitch(ctl.questions!.pitch!.round, share: false));
    await ctl.run();
    expect(ctl.phase, Phase.done);
    expect(ctl.youtubeOutput, isNull);
    expect(ctl.youtubeCopyMissing, isFalse);

    // Switched on in Settings afterwards: the finished game says it has none, and run makes just that.
    await settings.set('youtubeCopy', true);
    expect(ctl.youtubeCopyMissing, isTrue);
    final game = File(ctl.output!);
    final made = game.lastModifiedSync();
    final fractions = <double?>[];
    ctl.addListener(() => fractions.add(ctl.fraction));
    await ctl.run();
    expect(ctl.phase, Phase.done);
    expect(ctl.youtubeOutput, endsWith('fullgame/game-youtube.mp4'));
    expect(File(ctl.youtubeOutput!).existsSync(), isTrue);
    expect(ctl.youtubeCopyMissing, isFalse);
    expect(game.lastModifiedSync(), made);
    expect(fractions.whereType<double>(), isEmpty); // the game wasn't processed again
    expect((jsonDecode(File('${ctl.folder!.path}/job.json').readAsStringSync()) as Map)['output'], {
      'height': 1080,
      'youtubeCopy': true,
    });

    // A new launch finds both.
    final again = controller(fakeServer());
    await again.open();
    expect(again.phase, Phase.done);
    expect(again.youtubeOutput, ctl.youtubeOutput);

    // 1440p only: game.mp4 is the YouTube file, no copy is asked for.
    await settings.set('outputHeight', 1440);
    expect(settings.youtubeCopy, isFalse);
  });

  test('offline, sharing says so and the game carries on', () async {
    final ctl = controller(fakeServer()); // no contributions routes: 404
    await ctl.open();
    await ctl.startDownload();
    await ctl.answer((a) => a.approvePitch(ctl.questions!.pitch!.round, share: true));
    await settings.setSharingAgreed(true);
    await ctl.sendAgreed();
    expect(ctl.shareError, contains('404'));
    expect(ctl.sharedNames, isEmpty);
    expect(ctl.phase, Phase.readyToRun);
    expect(ctl.error, isNull);
  });

  test('a recording still uploading is not downloaded', () async {
    final ctl = controller(fakeServer(status: 'uploading'));
    await ctl.open();
    expect(ctl.phase, Phase.needsDownload);
    expect(ctl.error, contains('still uploading'));
    expect(ctl.awaitingUpload, isTrue);
  });

  test('a game opened while uploading is ready when asked again after the upload finishes', () async {
    var status = 'uploading';
    final ctl = controller(fakeServer(liveStatus: () => status));
    await ctl.open();
    expect(ctl.awaitingUpload, isTrue);
    status = 'ready';
    await ctl.open();
    expect(ctl.awaitingUpload, isFalse);
    expect(ctl.error, isNull);
    expect(ctl.recording!.ready, isTrue);
  });

  test('deleting a game from this Mac: its folder goes, the record of what was shared stays', () async {
    final ctl = controller(fakeServer());
    await ctl.open();
    expect(ctl.canDeleteLocal, isFalse); // nothing here yet
    await ctl.startDownload();
    expect(ctl.phase, Phase.questions);
    final dir = ctl.folder!;
    expect(settings.knownGame(recId), isNotNull);
    expect(ctl.canDeleteLocal, isTrue);
    expect(await ctl.localBytes(), greaterThan(seg.length));

    await ctl.deleteLocal();
    expect(ctl.error, isNull);
    expect(dir.existsSync(), isFalse);
    expect(settings.knownGame(recId), isNull);
    expect(ctl.phase, Phase.needsDownload);
    expect(ctl.questions, isNull);
    expect(ctl.canDeleteLocal, isFalse);

    // Downloaded again, with something shared from it: that record is all that is left.
    await ctl.startDownload();
    expect(ctl.phase, Phase.questions);
    final sent = SentRecord.fileIn(dir)..createSync(recursive: true);
    sent.writeAsStringSync('{"stopped": false, "sent": {"pitch": {"contributionId": "c1", "digest": "d"}}}');
    File('${dir.path}/engine/share/pitch.json').writeAsStringSync('{}');
    await ctl.deleteLocal();
    expect(ctl.error, isNull);
    expect([for (final e in dir.listSync(recursive: true)) e.path.substring(dir.path.length + 1)]..sort(), [
      'engine',
      'engine/share',
      'engine/share/sent.json',
    ]);
    expect((await SentRecord.read(dir)).idOf('pitch'), 'c1');
    expect(ctl.phase, Phase.needsDownload);
    expect(ctl.canDeleteLocal, isFalse);
    expect(settings.knownGame(recId)!.folder, dir.path);
  });

  test('without an engine it says where to set one', () async {
    await settings.set('enginePath', '/nonexistent/osb-engine');
    final ctl = controller(fakeServer());
    await ctl.open();
    await ctl.startDownload();
    expect(ctl.error, contains('No processing engine'));
  });

  test('a game is found where it was put, as far along as it was, after the work folder changes', () async {
    await settings.set('maxChunks', 1);
    final first = controller(fakeServer());
    await first.open();
    await first.startDownload();
    expect(first.phase, Phase.questions);
    final was = first.folder!.path;

    // The app opened again: the same settings file, another work folder
    // and no maxChunks.
    final saved = (jsonDecode(settings.file.readAsStringSync()) as Map).cast<String, Object?>();
    settings = Settings.inMemory(settings.file, saved);
    await settings.set('workFolder', '${work.path}/elsewhere');
    await settings.set('maxChunks', null);
    final again = controller(fakeServer());
    await again.open();
    expect(again.folder!.path, was);
    expect(again.phase, Phase.questions);
    expect((jsonDecode(File('$was/job.json').readAsStringSync()) as Map)['options'], {'maxChunks': 1});

    // Its folder gone, it goes where games go now.
    Directory(was).deleteSync(recursive: true);
    await again.open();
    expect(again.folder!.path, startsWith('${work.path}/elsewhere/'));
    expect(again.phase, Phase.needsDownload);
  });

  test('the games folder is named by date and game, and by recording when there are several', () {
    expect(recordingFolder('/w', summary, recId, onlyRecording: true), '/w/2026-10-15 09.23 11111111');
    expect(recordingFolder('/w', summary, recId, onlyRecording: false), '/w/2026-10-15 09.23 11111111/99999999');
  });
}
