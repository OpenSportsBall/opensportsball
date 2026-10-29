// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opensportsball/src/role.dart';
import 'package:opensportsball/src/session/activity.dart';
import 'package:opensportsball/src/storage/store.dart';
import 'package:opensportsball/src/upload/account.dart';
import 'package:opensportsball/src/upload/grant_link.dart';
import 'package:opensportsball/src/upload/upload_service.dart';

import 'fakes.dart';
import 'upload_fakes.dart';

/// Main was not linked at the game, so its Secondary never got a grant.
/// Later the website sends this phone an upload permission link.
void main() {
  final ticket = 'osbg_${'L' * 43}';
  String link({String game = 'game-1', String? exp, String api = 'https://api.test'}) =>
      Uri(scheme: 'opensportsball', host: 'grant', queryParameters: {
        'v': '1',
        'api': api,
        'account': 'acc-main',
        'game': game,
        'ticket': ticket,
        'exp': exp ?? DateTime.now().toUtc().add(const Duration(days: 7)).toIso8601String(),
      }).toString();

  group('parseGrantUri', () {
    test('reads a whole link as an unbound ticket for its game', () {
      final g = parseGrantUri(link())!;
      expect(g.token, ticket);
      expect(g.gameId, 'game-1');
      expect(g.accountId, 'acc-main');
      expect(g.apiUrl, 'https://api.test');
      expect(g.unredeemed, isTrue);
    });

    test('refuses anything else', () {
      expect(parseGrantUri('opensportsball://link?v=1'), isNull);
      expect(parseGrantUri(link().replaceFirst('v=1', 'v=2')), isNull);
      expect(parseGrantUri(link(api: 'http://api.test')), isNull);
      expect(parseGrantUri(link(exp: 'soon')), isNull);
      expect(parseGrantUri(link().replaceFirst(ticket, 'osbd_${'L' * 43}')), isNull);
      expect(parseGrantUri(link().replaceFirst('&game=game-1', '')), isNull);
    });
  });

  group('openGrantLink', () {
    late FakeBackend backend;
    var offline = false;
    late AppStore store;
    late AccountManager account;
    late UploadService uploads;

    setUp(() async {
      backend = FakeBackend()..ticketsIssued.add(ticket);
      offline = false;
      final client = MockClient((req) {
        if (offline) throw http.ClientException('no internet');
        final copy = http.Request(req.method, req.url)
          ..headers.addAll(req.headers)
          ..bodyBytes = req.bodyBytes;
        return backend.client.send(copy).then(http.Response.fromStream);
      });
      store = await tempStore('cccccccc');
      account = await fakeAccount(store, client); // not linked, like most Secondaries
      uploads = UploadService(
          store: store, account: account, client: client, network: FakeNetwork(), activity: DeviceActivity());
    });

    Future<GrantLinkResult> open([String? raw]) =>
        openGrantLink(raw ?? link(), store: store, account: account, uploads: uploads);

    test('binds the ticket to this phone, and the waiting recording uploads with it', () async {
      await writeRecording(store, recordingId: 'rec-1', sizes: [300, 50], role: DeviceRole.secondary);
      await uploads.runPass();
      expect(uploads.recordings.single.blocked, UploadPhase.waitingForGrant);

      final r = await open();
      expect(r.title, 'Upload permission added');
      expect(backend.redeemed[ticket], ('game-1', store.identity.deviceId));
      expect((await account.grantFor('game-1'))!.unredeemed, isFalse);

      expect(await uploads.runPass(), PassResult.done);
      expect(uploads.recordings.single.complete, isTrue);
      // Every upload call carries the ticket, now this phone's grant.
      expect({
        for (final (call, token) in backend.calls)
          if (call != 'POST /grants/redeem') token
      }, {
        ticket
      });
    });

    test('a phone with no Secondary recording of that game leaves the link unused', () async {
      await writeRecording(store, recordingId: 'rec-1', sizes: [10], role: DeviceRole.secondary);
      expect((await open(link(game: 'game-2'))).title, 'No recording of that game');
      expect(backend.log, isEmpty);
    });

    test('a recording made as Main does not count: it uploads with the phone\'s own link', () async {
      await writeRecording(store, recordingId: 'rec-1', sizes: [10]);
      expect((await open()).title, 'No recording of that game');
      expect(backend.log, isEmpty);
    });

    test('without internet the ticket is kept, and bound before the first upload', () async {
      await writeRecording(store, recordingId: 'rec-1', sizes: [100], role: DeviceRole.secondary);
      offline = true;
      expect((await open()).title, 'Upload permission saved');
      expect((await account.grantFor('game-1'))!.unredeemed, isTrue);
      expect(backend.redeemed, isEmpty);

      offline = false;
      expect(await uploads.runPass(), PassResult.done);
      expect(backend.redeemed[ticket], ('game-1', store.identity.deviceId));
      expect(uploads.recordings.single.complete, isTrue);
    });

    test('a refused link says why and changes nothing', () async {
      await writeRecording(store, recordingId: 'rec-1', sizes: [100], role: DeviceRole.secondary);
      backend.redeemStatus = 409;
      final r = await open();
      expect(r.title, 'Could not use this link');
      expect(r.message, contains('refused'));
      expect(await account.grantFor('game-1'), isNull);
    });

    test('an expired or broken link is not sent to the server', () async {
      await writeRecording(store, recordingId: 'rec-1', sizes: [100], role: DeviceRole.secondary);
      expect((await open(link(exp: '2020-01-01T00:00:00Z'))).title, 'Link expired');
      expect((await open('opensportsball://grant?v=1')).title, 'Link not recognised');
      expect(backend.log, isEmpty);
    });

    test('a phone that already has permission keeps it', () async {
      await writeRecording(store, recordingId: 'rec-1', sizes: [100], role: DeviceRole.secondary);
      await open();
      backend.log.clear();
      expect((await open()).title, 'Already allowed');
      expect(backend.log, isEmpty);
    });
  });
}
