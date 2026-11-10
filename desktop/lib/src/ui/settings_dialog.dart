// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../services.dart';

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

  Future<void> _save() async {
    final s = widget.settings;
    await s.set('workFolder', _work.text.trim().isEmpty ? null : _work.text.trim());
    await s.set('enginePath', _engine.text.trim().isEmpty ? null : _engine.text.trim());
    await s.set('outputHeight', _height);
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
            DropdownButtonFormField<int>(
              initialValue: _height,
              decoration: const InputDecoration(labelText: 'Video size'),
              items: const [
                DropdownMenuItem(value: 1080, child: Text('1080p')),
                DropdownMenuItem(value: 1440, child: Text('1440p (YouTube shows it sharper; a bigger file)')),
              ],
              onChanged: (v) => setState(() => _height = v ?? 1080),
            ),
            const SizedBox(height: 16),
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
