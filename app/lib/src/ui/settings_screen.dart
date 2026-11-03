// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../model.dart';
import '../storage/store.dart';
import '../upload/account.dart';
import '../upload/upload_service.dart';
import 'account_screen.dart';

/// Recording settings and the account link. Only the Main phone's recording
/// settings matter: it sends them to the Secondary when they pair.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen(
      {super.key, required this.store, required this.account, required this.uploads});
  final AppStore store;
  final AccountManager account;
  final UploadService uploads;
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
      appBar: AppBar(title: const Text('Settings')),
      // SafeArea so the headings line up with the tiles, which already
      // inset themselves past the landscape notch.
      body: SafeArea(
          child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          const _SectionHeader('Account'),
          ListenableBuilder(
            listenable: widget.account,
            builder: (context, _) {
              final a = widget.account;
              final linked = a.linked && !a.revoked;
              return ListTile(
                title:
                    Text(linked ? 'Linked to an account' : 'Link to account'),
                subtitle: Text(linked
                    ? a.link!.email ?? Uri.parse(a.link!.apiUrl).host
                    : a.revoked
                        ? 'This phone was unlinked; link it again to upload.'
                        : 'Sign in, or link this phone to a website account, to upload recordings.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => AccountScreen(account: a))),
              );
            },
          ),
          ListenableBuilder(
            listenable: widget.uploads,
            builder: (context, _) => SwitchListTile(
              title: const Text('Upload to cloud'),
              subtitle: const Text(
                  'Off: recordings stay on this phone and nothing is uploaded until '
                  'this is turned back on.'),
              value: widget.uploads.enabled,
              onChanged: widget.uploads.setEnabled,
            ),
          ),
          const SizedBox(height: 16),
          const _SectionHeader('Recording'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
                'Set these on the Main phone; the Secondary uses the Main phone\'s settings.'),
          ),
          const SizedBox(height: 16),
          ListTile(
            title: const Text('Sport'),
            subtitle: const Text(
                'Processing is tuned for soccer. Choose Other for anything else.'),
            trailing: SegmentedButton<Sport>(
              segments: [
                for (final s in Sport.values)
                  ButtonSegment(value: s, label: Text(s.label)),
              ],
              selected: {_s.sport},
              onSelectionChanged: (v) => _set(_s.copyWith(sport: v.first)),
            ),
          ),
          ListTile(
            title: const Text('Resolution'),
            subtitle: Text(_s.resolution == Resolution.uhd4k
                ? 'Best for ball tracking. About 16 GB per hour per phone.'
                : 'Longer battery life. About 7 GB per hour per phone.'),
            trailing: SegmentedButton<Resolution>(
              segments: [
                for (final r in Resolution.values)
                  ButtonSegment(value: r, label: Text(r.label)),
              ],
              selected: {_s.resolution},
              onSelectionChanged: (v) => _set(_s.copyWith(resolution: v.first)),
            ),
          ),
          ListTile(
            title: const Text('Segment length'),
            subtitle: const Text(
                'Recording is split into files of this length. Use 1 minute to test.'),
            trailing: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1 min')),
                ButtonSegment(value: 5, label: Text('5 min')),
                ButtonSegment(value: 10, label: Text('10 min')),
              ],
              selected: {_s.segmentMinutes},
              onSelectionChanged: (v) =>
                  _set(_s.copyWith(segmentMinutes: v.first)),
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
      )),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
