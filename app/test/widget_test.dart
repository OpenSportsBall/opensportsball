// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';

import 'package:sportsballvideo/main.dart';
import 'package:sportsballvideo/src/role.dart';

void main() {
  testWidgets('role picker offers Main and Secondary', (tester) async {
    await tester.pumpWidget(const SportsBallVideoApp());

    for (final role in DeviceRole.values) {
      expect(find.text(role.label), findsOneWidget);
      expect(find.text(role.description), findsOneWidget);
    }
  });
}
