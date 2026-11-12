// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../services.dart';
import 'share_views.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.settings});
  final Settings settings;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final _work = TextEditingController(text: widget.settings.workFolder);
  late final _engine = TextEditingController(text: widget.settings.enginePath ?? '');
  late int _height = widget.settings.outputHeight;
  late bool _youtubeCopy = widget.settings.youtubeCopy;

  Future<void> _save() async {
    final s = widget.settings;
    await s.set('workFolder', _work.text.trim().isEmpty ? null : _work.text.trim());
    await s.set('enginePath', _engine.text.trim().isEmpty ? null : _engine.text.trim());
    await s.set('outputHeight', _height);
    await s.set('youtubeCopy', _youtubeCopy && _height < 1440);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final found = widget.settings.findEngine();
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _work,
              decoration: const InputDecoration(
                labelText: 'Games folder',
                helperText: 'Footage and videos go here: about 100 GB while a game is processed.',
              ),
            ),
            const SizedBox(height: 16),
            // One choice of three: the copy only makes sense beside 1080p.
            DropdownButtonFormField<String>(
              initialValue: _height >= 1440 ? '1440' : (_youtubeCopy ? '1080+youtube' : '1080'),
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Video size',
                helperText: 'YouTube shows a 1440p upload much sharper than a 1080p one.',
              ),
              items: const [
                DropdownMenuItem(value: '1080', child: Text('1080p')),
                DropdownMenuItem(
                  value: '1080+youtube',
                  child: Text('1080p, and a 1440p copy for YouTube (25 GB more)', overflow: TextOverflow.ellipsis),
                ),
                DropdownMenuItem(value: '1440', child: Text('1440p only (a bigger file)')),
              ],
              onChanged: (v) => setState(() {
                _height = v == '1440' ? 1440 : 1080;
                _youtubeCopy = v == '1080+youtube';
              }),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.settings.sharingAgreed,
              onChanged: (v) async {
                // Switching it on shows what is shared, to agree to.
                if (v) {
                  await showShareConsent(context, widget.settings);
                } else {
                  await widget.settings.setSharingAgreed(false);
                }
                if (mounted) setState(() {});
              },
              title: const Text('Share what I check and mark, to improve OpenSportsBall'),
              subtitle: const Text(
                'Off: nothing more is sent, and marking the ball is locked. What was already shared stays until you '
                'withdraw it, on its game here or on the website (Account).',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _engine,
              decoration: InputDecoration(
                labelText: 'Processing engine (for development)',
                helperText: found == null ? 'None found.' : 'Using $found',
                helperMaxLines: 2,
                hintText: 'The app’s own, or a packaged osb-engine/osb-engine',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
