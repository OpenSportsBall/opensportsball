// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:opensportsball/main.dart';
import 'package:opensportsball/src/app_services.dart';
import 'package:opensportsball/src/role.dart';
import 'package:opensportsball/src/session/activity.dart';
import 'package:opensportsball/src/storage/store.dart';
import 'package:opensportsball/src/ui/account_screen.dart';
import 'package:opensportsball/src/ui/settings_screen.dart';
import 'package:opensportsball/src/ui/uploads_screen.dart';
import 'package:opensportsball/src/upload/account.dart';
import 'package:opensportsball/src/upload/sign_in.dart';
import 'package:opensportsball/src/upload/upload_service.dart';

import 'fakes.dart';
import 'upload_fakes.dart';

Future<AppServices> fakeServices(AppStore store) async {
  final client = MockClient((_) async => http.Response('{}', 404));
  final account = AccountManager(store: store, secrets: MemorySecretStore(), client: client);
  await account.load();
  final uploads = UploadService(
    store: store,
    account: account,
    client: client,
    network: FakeNetwork(),
    activity: DeviceActivity(),
  );
  return AppServices(store: store, account: account, uploads: uploads);
}

void main() {
  testWidgets('role picker offers Main and Secondary', (tester) async {
    final store = await tester.runAsync(() => tempStore('cccccccc'));
    await tester.pumpWidget(
        OpenSportsBallApp(store: Future.value(store!), createServices: fakeServices));
    await tester.pumpAndSettle();

    for (final role in DeviceRole.values) {
      expect(find.text(role.label), findsOneWidget);
      expect(find.text(role.description), findsOneWidget);
    }
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Uploads'), findsOneWidget);
  });

  testWidgets('settings screen has an account section', (tester) async {
    final services = (await tester.runAsync(() async => fakeServices(await tempStore('eeeeeeee'))))!;
    await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
            store: services.store, account: services.account, uploads: services.uploads)));
    await tester.pumpAndSettle();
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Link to account'), findsOneWidget);
    expect(services.uploads.enabled, isTrue, reason: 'upload to cloud defaults on');
    await tester.tap(find.text('Upload to cloud'));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(services.store.uploadSettings.enabled, isFalse);
  });

  testWidgets('a linked phone offers deleting the account on the website', (tester) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final client = MockClient((_) async => http.Response('{}', 404));
    final account = (await tester.runAsync(() async => fakeAccount(await tempStore('ffffffff'), client, accountId: 'acc-1')))!;
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(
        home: AccountScreen(account: account, openUrl: (u) async {
      opened.add(u);
      return true;
    })));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete account…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);

    await tester.tap(find.text('Delete account…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('$defaultSiteUrl/account')]);
    expect(account.linked, isTrue, reason: 'the phone stays linked until the website deletes the account');
  });

  testWidgets('uploads screen prompts to link and offers the Wi-Fi switch', (tester) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() async => fakeServices(await tempStore('dddddddd'))))!;
    await tester.pumpWidget(MaterialApp(
        home: UploadsScreen(uploads: services.uploads, account: services.account)));
    await tester.pumpAndSettle();
    expect(find.text('Link to account'), findsOneWidget);
    expect(find.text('Upload on Wi-Fi only'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(services.uploads.paused, isTrue);
    expect(find.text('Resume'), findsOneWidget);
  });
}
