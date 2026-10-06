// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';

import 'package:sportsballvideo/main.dart';
import 'package:sportsballvideo/src/role.dart';

import 'fakes.dart';

void main() {
  testWidgets('role picker offers Main and Secondary', (tester) async {
    final store = await tester.runAsync(() => tempStore('cccccccc'));
    await tester.pumpWidget(SportsBallVideoApp(store: Future.value(store!)));
    await tester.pumpAndSettle();

    for (final role in DeviceRole.values) {
      expect(find.text(role.label), findsOneWidget);
      expect(find.text(role.description), findsOneWidget);
    }
  });
}
