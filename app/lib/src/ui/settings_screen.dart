// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../model.dart';
import '../storage/store.dart';

/// Recording settings. Only the Main phone's settings matter: it sends them
/// to the Secondary when they pair.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.store});
  final AppStore store;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late RecordingSettings _s = widget.store.settings;

  Future<void> _set(RecordingSettings s) async {
    setState(() => _s = s);
    await widget.store.saveSettings(s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recording settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Set these on the Main phone; the Secondary uses the Main phone\'s settings.'),
          const SizedBox(height: 16),
          ListTile(
            title: const Text('Resolution'),
            subtitle: Text(_s.resolution == Resolution.uhd4k
                ? 'Best for ball tracking. About 16 GB per hour per phone.'
                : 'Longer battery life. About 7 GB per hour per phone.'),
            trailing: SegmentedButton<Resolution>(
              segments: [
                for (final r in Resolution.values) ButtonSegment(value: r, label: Text(r.label)),
              ],
              selected: {_s.resolution},
              onSelectionChanged: (v) => _set(_s.copyWith(resolution: v.first)),
            ),
          ),
          ListTile(
            title: const Text('Segment length'),
            subtitle: const Text('Recording is split into files of this length. Use 1 minute to test.'),
            trailing: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1 min')),
                ButtonSegment(value: 5, label: Text('5 min')),
                ButtonSegment(value: 10, label: Text('10 min')),
              ],
              selected: {_s.segmentMinutes},
              onSelectionChanged: (v) => _set(_s.copyWith(segmentMinutes: v.first)),
            ),
          ),
          SwitchListTile(
            title: const Text('Lock exposure'),
            subtitle: const Text(
                'Off: each phone adjusts to changing light. On: brightness is fixed '
                'when recording starts. White balance and focus are always locked.'),
            value: _s.lockExposure,
            onChanged: (v) => _set(_s.copyWith(lockExposure: v)),
          ),
          SwitchListTile(
            title: const Text('Darken screens while recording'),
            subtitle: const Text(
                'After 15 seconds of recording, both phones go black at minimum '
                'brightness to save battery and heat. Recording continues. Tap the '
                'screen to see it again.'),
            value: _s.darkenScreen,
            onChanged: (v) => _set(_s.copyWith(darkenScreen: v)),
          ),
        ],
      ),
    );
  }
}
