// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import 'src/role.dart';

void main() => runApp(const SportsBallVideoApp());

class SportsBallVideoApp extends StatelessWidget {
  const SportsBallVideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SportsBallVideo',
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: const RolePickerScreen(),
    );
  }
}

/// First screen: each phone chooses whether it controls the recording
/// (Main) or follows it (Secondary).
class RolePickerScreen extends StatelessWidget {
  const RolePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SportsBallVideo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final role in DeviceRole.values) ...[
              FilledButton(
                onPressed: () {
                  // TODO(phase-1): Main shows a pairing QR code and starts
                  // advertising over BLE; Secondary scans it and connects.
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(role.label),
                ),
              ),
              const SizedBox(height: 8),
              Text(role.description, textAlign: TextAlign.center),
              const SizedBox(height: 32),
            ],
          ],
        ),
      ),
    );
  }
}
