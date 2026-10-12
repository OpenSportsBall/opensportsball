// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opensportsball/src/role.dart';
import 'package:opensportsball/src/session/activity.dart';
import 'package:opensportsball/src/session/local_recorder.dart';
import 'package:opensportsball/src/storage/store.dart';
import 'package:opensportsball/src/upload/account.dart';
import 'package:opensportsball/src/upload/network.dart';
import 'package:opensportsball/src/upload/upload_service.dart';

import 'fakes.dart';
import 'upload_fakes.dart';

Future<AccountManager> linkedAccount(AppStore store, http.Client client) async {
  final secrets = MemorySecretStore()
    ..values['account_link'] = jsonEncode(
        const AccountLink(apiUrl: apiUrl, deviceToken: deviceToken, accountId: accountId).toJson());
  final account = AccountManager(store: store, secrets: secrets, client: client);
  await account.load();
  return account;
}

class Harness {
  Harness._(this.store, this.backend, this.account, this.network, this.activity);

  static Future<Harness> create({String name = 'aaaaaaaa', int partSize = 128}) async {
    final store = await tempStore(name);
    final backend = FakeBackend(partSize: partSize);
    return Harness._(store, backend, await linkedAccount(store, backend.client), FakeNetwork(),
        DeviceActivity());
  }

  final AppStore store;
  final FakeBackend backend;
  final AccountManager account;
  final FakeNetwork network;
  final DeviceActivity activity;
  final screen = <bool>[];

  UploadService service() => UploadService(
        store: store,
        account: account,
        client: backend.client,
        network: network,
        activity: activity,
        keepScreenOn: (on) async => screen.add(on),
        chunkBytes: 50,
      );

  Future<Map<String, Object?>> uploadJson(StoredRecording r) async =>
      (await store.readUploadJson(r.dir))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('linking', () {
    test('parses the link QR code and typed codes', () {
      final r = parseLinkUri('opensportsball://link?v=1&api=${Uri.encodeComponent('https://x.example.com/prod')}&code=ABCDEFGH');
      expect(r!.apiUrl, 'https://x.example.com/prod');
      expect(r.code, 'ABCDEFGH');
      expect(parseLinkUri('opensportsball://link?v=2&api=https%3A%2F%2Fx&code=ABCDEFGH'), isNull);
      expect(parseLinkUri('opensportsball://link?v=1&api=http%3A%2F%2Fx&code=ABCDEFGH'), isNull,
          reason: 'http is refused');
      expect(parseLinkUri('opensportsball://pair?v=1&game=x'), isNull);
      expect(normalizeLinkCode('abcd-efgh'), 'ABCDEFGH');
      expect(normalizeLinkCode('ABCD EFG2'), 'ABCDEFG2');
      expect(normalizeLinkCode('ABCDEFG1'), isNull, reason: '1 is not in the alphabet');
      expect(normalizeLinkCode('ABC'), isNull);
      expect(apiUri('https://a.test/prod/', '/uploads').toString(), 'https://a.test/prod/uploads');
    });

    test('links and stores the token', () async {
      final store = await tempStore('bbbbbbbb');
      late Map<String, Object?> sent;
      final client = MockClient((req) async {
        expect(req.url.toString(), 'https://api.test/devices/link');
        expect(req.headers.containsKey('Authorization'), isFalse);
        sent = (jsonDecode(req.body) as Map).cast();
        return http.Response(jsonEncode({'deviceToken': 'osbd_new', 'accountId': 'acc-9'}), 200);
      });
      final secrets = MemorySecretStore();
      final account = AccountManager(store: store, secrets: secrets, client: client);
      await account.load();
      expect(account.linked, isFalse);
      expect(account.knownApiUrl, isNull);

      await account.linkWith(const LinkRequest(apiUrl: apiUrl, code: 'ABCDEFGH'));
      expect(sent, {
        'code': 'ABCDEFGH',
        'deviceId': store.identity.deviceId,
        'platform': store.identity.platform,
        'model': store.identity.model,
      });
      expect(account.link!.deviceToken, 'osbd_new');
      expect(account.link!.accountId, 'acc-9');
      expect(secrets.values['account_link'], contains('osbd_new'));

      // Survives a restart; unlinking forgets the token but keeps the API.
      final again = AccountManager(store: store, secrets: secrets, client: client);
      await again.load();
      expect(again.link!.accountId, 'acc-9');
      await again.unlink();
      expect(again.linked, isFalse);
      expect(secrets.values, isEmpty);
      expect(again.knownApiUrl, apiUrl);
    });

    for (final (code, text) in [
      (404, 'not found'),
      (410, 'expired'),
      (409, 'different account'),
      (500, 'Linking failed (500: boom)'),
    ]) {
      test('link error $code', () async {
        final store = await tempStore('cccccccc');
        final account = AccountManager(
          store: store,
          secrets: MemorySecretStore(),
          client: MockClient((_) async =>
              http.Response(jsonEncode({'error': 'x', 'message': 'boom'}), code)),
        );
        await expectLater(
          account.linkWith(const LinkRequest(apiUrl: apiUrl, code: 'ABCDEFGH')),
          throwsA(isA<LinkException>().having((e) => e.message, 'message', contains(text))),
        );
        expect(account.linked, isFalse);
      });
    }

    test('link network failure', () async {
      final store = await tempStore('dddddddd');
      final account = AccountManager(
        store: store,
        secrets: MemorySecretStore(),
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(account.linkWith(const LinkRequest(apiUrl: apiUrl, code: 'ABCDEFGH')),
          throwsA(isA<LinkException>()));
    });
  });

  group('upload queue', () {
    test('uploads the manifest, then each segment in parts', () async {
      final h = await Harness.create();
      final rec = await writeRecording(h.store, recordingId: 'rec-1', sizes: [300, 500]);
      final s = h.service();

      expect(await s.runPass(), PassResult.done);
      expect(s.phase, UploadPhase.idle);

      expect(h.backend.manifests.keys, ['rec-1']);
      final apiCalls = h.backend.log.where((l) => !l.startsWith('PUT s3')).toList();
      expect(apiCalls.first, 'PUT /games/game-1/recordings/rec-1/manifest');
      for (final f in rec.recording.segments) {
        expect(h.backend.files['rec-1/${f.fileName}'], File('${rec.dir.path}/${f.fileName}').readAsBytesSync());
      }
      // 300 B → 3 parts, 500 B → 4 parts of 128 B.
      expect(h.backend.putTotal, 7);

      final json = await h.uploadJson(rec);
      expect(json['accountId'], accountId);
      expect((json['manifest'] as Map)['status'], 'uploading');
      expect((json['segments'] as Map).values.every((v) => (v as Map)['done'] == true), isTrue);
      expect(s.recordings.single.complete, isTrue);
      expect(s.pendingBytesTotal, 0);

      // Screen kept awake while uploading, released after.
      expect(h.screen, [true, false]);

      // Nothing left to do on the next pass.
      h.backend.log.clear();
      expect(await s.runPass(), PassResult.done);
      expect(h.backend.log, isEmpty);
    });

    test('uploads oldest recordings first; Secondary sends its own segment list', () async {
      final h = await Harness.create();
      await writeRecording(h.store,
          recordingId: 'new', sizes: [10], role: DeviceRole.secondary, createdAtMs: 5000);
      await writeRecording(h.store,
          recordingId: 'old', sizes: [10], role: DeviceRole.secondary, createdAtMs: 1000);
      await writeRecording(h.store, recordingId: 'live', sizes: [10], stopped: false, createdAtMs: 0);
      final s = h.service();
      expect(await s.runPass(), PassResult.done);
      expect(h.backend.manifests, isEmpty);
      expect(h.backend.reports.keys.toSet(), {'old', 'new'});
      final report = h.backend.reports['old']!;
      expect(report['role'], 'secondary');
      expect((report['segments'] as List).single['objectKey'],
          '${h.store.identity.deviceId}/${h.store.identity.deviceId}_000.mp4');
      expect(h.backend.files.length, 2);
      final starts = h.backend.log.where((l) => l == 'POST /uploads').length;
      expect(starts, 2, reason: 'the unfinished recording is skipped');
      expect(s.recordings.map((r) => r.recording.recordingId), ['live', 'old', 'new']);
    });

    test('Main writes a missing manifest itself (e.g. a recording recovered after a crash)', () async {
      final h = await Harness.create();
      await writeRecording(h.store, recordingId: 'rec-1', sizes: [100], manifest: false);
      final s = h.service();
      expect(await s.runPass(), PassResult.done);
      expect(h.backend.files.length, 1);
      final m = h.backend.manifests['rec-1']!;
      expect((m['devices'] as List).single['role'], 'main');
      expect(s.recordings.single.complete, isTrue);
    });

    test('resumes after a failure mid-file, after a restart', () async {
      final h = await Harness.create();
      final rec = await writeRecording(h.store, recordingId: 'rec-1', sizes: [300, 500]);
      final name = rec.recording.segments[1].fileName;
      h.backend.failPut.add((name, 3));

      expect(await h.service().runPass(), PassResult.retry);
      var json = await h.uploadJson(rec);
      final seg = (json['segments'] as Map)[name] as Map;
      expect(seg['done'], false);
      expect(seg['uploadId'], isNotNull);
      expect((seg['parts'] as Map).keys, ['1', '2']);

      // "Restart": a new service reads upload.json and asks the server.
      final s2 = h.service();
      expect(await s2.runPass(), PassResult.done);
      expect(h.backend.putCount(name, 1), 1);
      expect(h.backend.putCount(name, 2), 1);
      expect(h.backend.putCount(name, 3), 2);
      expect(h.backend.putCount(name, 4), 1);
      expect(h.backend.files['rec-1/$name'], File('${rec.dir.path}/$name').readAsBytesSync());
      json = await h.uploadJson(rec);
      expect(((json['segments'] as Map)[name] as Map)['done'], true);
    });

    test('resumes from the server when upload.json lost the parts', () async {
      final h = await Harness.create();
      final rec = await writeRecording(h.store, recordingId: 'rec-1', sizes: [500]);
      final name = rec.recording.segments[0].fileName;
      h.backend.failPut.add((name, 3));
      expect(await h.service().runPass(), PassResult.retry);
      await File('${rec.dir.path}/upload.json').delete();

      expect(await h.service().runPass(), PassResult.done);
      expect(h.backend.putCount(name, 1), 1, reason: 'completedParts from the server are reused');
      expect(h.backend.files['rec-1/$name']!.length, 500);
    });

    test('alreadyUploaded marks the file done without sending it', () async {
      final h = await Harness.create();
      final rec = await writeRecording(h.store, recordingId: 'rec-1', sizes: [300, 200]);
      final first = rec.recording.segments[0];
      h.backend.files['rec-1/${first.fileName}'] = File('${rec.dir.path}/${first.fileName}').readAsBytesSync();

      expect(await h.service().runPass(), PassResult.done);
      expect(h.backend.putCount(first.fileName, 1), 0);
      final json = await h.uploadJson(rec);
      expect(((json['segments'] as Map)[first.fileName] as Map)['done'], true);
    });

    test('expired upload URLs are requested again', () async {
      final h = await Harness.create();
      final rec = await writeRecording(h.store, recordingId: 'rec-1', sizes: [300]);
      final name = rec.recording.segments[0].fileName;
      h.backend.expirePut.add((name, 2));
      expect(await h.service().runPass(), PassResult.done);
      expect(h.backend.log.where((l) => l == 'POST /uploads').length, 2);
      expect(h.backend.files['rec-1/$name']!.length, 300);
    });

    test('401 stops uploading and asks to link again', () async {
      final h = await Harness.create();
      await writeRecording(h.store, recordingId: 'rec-1', sizes: [300]);
      h.backend.unauthorized = true;
      final s = h.service();
      expect(await s.runPass(), PassResult.unauthorized);
      expect(s.phase, UploadPhase.unlinked);
      expect(s.phase.label, 'This phone was unlinked; link it again');
      expect(h.account.revoked, isTrue);

      h.backend.log.clear();
      expect(await s.runPass(), PassResult.blocked);
      expect(h.backend.log, isEmpty);
    });

    test('server errors are retried; bad requests mark the recording failed', () async {
      final h = await Harness.create();
      await writeRecording(h.store, recordingId: 'rec-1', sizes: [100], manifest: false);
      final s = h.service();
      // Delete the file: a permanent, per-recording problem.
      final r = (await h.store.listRecordings()).single;
      await r.segmentFiles.single.delete();
      expect(await s.runPass(), PassResult.someFailed);
      expect(s.recordings.single.error, contains('missing'));
      expect(s.phase, UploadPhase.failed);
    });

    test('Wi-Fi only: waits on mobile data until overridden once', () async {
      final h = await Harness.create();
      await writeRecording(h.store, recordingId: 'rec-1', sizes: [100]);
      h.network.kind = NetworkKind.metered;
      final s = h.service();

      expect(s.wifiOnly, isTrue, reason: 'default on');
      expect(await s.runPass(), PassResult.blocked);
      expect(s.phase, UploadPhase.waitingForWifi);
      expect(s.blockedByMobileData, isTrue);
      expect(h.backend.log, isEmpty);

      s.useMobileDataOnce();
      expect(await s.runPass(), PassResult.done);
      expect(h.backend.files.length, 1);
      expect(s.mobileOverride, isFalse, reason: 'one-time: cleared when the queue is empty');

      await writeRecording(h.store, recordingId: 'rec-2', sizes: [100], createdAtMs: 9000);
      expect(await s.runPass(), PassResult.blocked);
      await s.setWifiOnly(false);
      expect(h.store.uploadSettings.wifiOnly, isFalse);
      expect(await s.runPass(), PassResult.done);
      expect(h.backend.files.length, 2);

      h.network.kind = NetworkKind.offline;
      expect(await s.runPass(), PassResult.blocked);
      expect(s.phase, UploadPhase.offline);
    });

    test('no uploads while recording; a recording that starts mid-upload stops it', () async {
      final h = await Harness.create();
      final rec = await writeRecording(h.store, recordingId: 'rec-1', sizes: [500]);
      final name = rec.recording.segments[0].fileName;
      final s = h.service();
      final owner = Object();

      h.activity.setRecording(owner, true);
      expect(await s.runPass(), PassResult.blocked);
      expect(s.phase, UploadPhase.recording);
      expect(h.backend.log, isEmpty);

      h.activity.setRecording(owner, false);
      h.backend.onPut = (file, part) {
        if (part == 2) h.activity.setRecording(owner, true);
      };
      expect(await s.runPass(), PassResult.interrupted);
      expect(h.backend.putCount(name, 3), 0);
      expect(s.phase, UploadPhase.recording);

      h.backend.onPut = null;
      h.activity.setRecording(owner, false);
      expect(await s.runPass(), PassResult.done);
      expect(h.backend.files['rec-1/$name']!.length, 500);
    });

    test('pause stops the queue', () async {
      final h = await Harness.create();
      await writeRecording(h.store, recordingId: 'rec-1', sizes: [100]);
      final s = h.service()..setPaused(true);
      expect(await s.runPass(), PassResult.blocked);
      expect(s.phase, UploadPhase.paused);
      s.setPaused(false);
      expect(await s.runPass(), PassResult.done);
    });

    test('re-linking to another account uploads again', () async {
      final h = await Harness.create();
      final rec = await writeRecording(h.store, recordingId: 'rec-1', sizes: [100]);
      expect(await h.service().runPass(), PassResult.done);
      final json = await h.uploadJson(rec);
      json['accountId'] = 'someone-else';
      await h.store.writeUploadJson(rec.dir, json);
      final s = h.service();
      await s.refresh();
      expect(s.recordings.single.complete, isFalse);
    });

    test('the recorder tells DeviceActivity when it records', () async {
      final store = await tempStore('eeeeeeee');
      final activity = DeviceActivity();
      final camera = FakeCamera();
      final recorder = LocalRecorder(
          camera: camera, store: store, role: DeviceRole.main, activity: activity);
      await recorder.open(store.settings.toCaptureConfig());
      expect(activity.cameraOpen, isTrue);
      expect(activity.recording, isFalse);
      await recorder.start(gameId: 'g', recordingId: 'r');
      expect(activity.recording, isTrue);
      await recorder.stop();
      expect(activity.recording, isFalse);
      await recorder.close();
      expect(activity.cameraOpen, isFalse);
    });

    test('backoff doubles up to ten minutes', () {
      expect(backoffDelay(0), const Duration(seconds: 5));
      expect(backoffDelay(1), const Duration(seconds: 10));
      expect(backoffDelay(4), const Duration(seconds: 80));
      expect(backoffDelay(50), const Duration(minutes: 10));
    });

    test('the loop uploads when started and when kicked', () async {
      final h = await Harness.create();
      final s = h.service()..start();
      await eventually(() => s.phase == UploadPhase.idle);
      await writeRecording(h.store, recordingId: 'rec-1', sizes: [100]);
      s.kick();
      await eventually(() => h.backend.files.length == 1);
      s.dispose();
    });
  });
}
