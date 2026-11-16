// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../brand.dart';
import '../game_controller.dart';
import '../regenerate.dart';

/// Asks which stages of processing to do again, then makes the video again.
Future<void> showRegenerate(BuildContext context, GameController ctl) async {
  final picked = await showDialog<Set<RegenPart>>(
    context: context,
    builder: (_) => RegenerateDialog(
      // A game with no video (stopped part-way, or its video moved away) has the video to make whatever is picked.
      hasVideo: ctl.phase == Phase.done,
      youtubeCopy: ctl.settings.youtubeCopy,
    ),
  );
  if (picked != null && picked.isNotEmpty) await ctl.regenerate(picked);
}

class RegenerateDialog extends StatefulWidget {
  const RegenerateDialog({super.key, required this.hasVideo, required this.youtubeCopy});

  /// The game video is there: without it, the video is always made.
  final bool hasVideo;

  /// Settings ask for a 1440p copy for YouTube.
  final bool youtubeCopy;

  @override
  State<RegenerateDialog> createState() => _RegenerateDialogState();
}

class _RegenerateDialogState extends State<RegenerateDialog> {
  /// What the user ticked; what is made again is [_parts].
  late final Set<RegenPart> _picked = {RegenPart.video};

  Set<RegenPart> _with(Set<RegenPart> picked) =>
      regenWith({...picked, if (!widget.hasVideo) RegenPart.video}, youtubeCopy: widget.youtubeCopy);

  Set<RegenPart> get _parts => _with(_picked);

  /// Made again because of another choice (or for want of a video), so not the user's to switch off.
  bool _impliedWithout(RegenPart p) => _with({..._picked}..remove(p)).contains(p);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = BrandColors.of(context);
    final parts = _parts;

    Widget row(RegenPart p, String title, String detail) {
      final forced = _impliedWithout(p);
      return CheckboxListTile(
        key: ValueKey(p),
        value: parts.contains(p),
        onChanged: forced
            ? null
            : (v) => setState(() {
                v == true ? _picked.add(p) : _picked.remove(p);
              }),
        title: Text(title),
        subtitle: Text(detail, style: t.bodySmall?.copyWith(color: c.inkMuted)),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
      );
    }

    final video = parts.contains(RegenPart.video);
    return AlertDialog(
      title: const Text('Regenerate the video'),
      content: SizedBox(
        width: 480,
        // A short window: the choices scroll, the buttons stay.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose what the engine does again. What is switched off is kept from last time. '
                'Your checks of the pitch and the cameras are kept either way.',
                style: t.bodyMedium,
              ),
              const SizedBox(height: 8),
              row(RegenPart.ball, 'Find the ball', 'Looks for the ball in every frame again. The slowest part.'),
              row(
                RegenPart.players,
                'Find the players',
                'Works out again who is on the pitch: each team, the keepers and the referee.',
              ),
              row(
                RegenPart.video,
                'Follow the play and make the video',
                widget.hasVideo
                    ? 'Aims the camera again and renders the video. Always done when the ball or the players are found again.'
                    : 'Aims the camera and renders the video. This game has no video yet, so it is always done.',
              ),
              if (widget.youtubeCopy)
                row(
                  RegenPart.youtube,
                  'Make the YouTube copy',
                  'The 1440p copy, made from the video: always done when the video is made again.',
                ),
              const SizedBox(height: 12),
              if (video && widget.hasVideo)
                Text(
                  'The game video in this game’s folder is deleted before the new one is made. '
                  'To keep it, move it out of the folder first.',
                  style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                )
              else if (parts.contains(RegenPart.youtube) && !video)
                Text('The YouTube copy is deleted and made again; the game video stays.', style: t.bodyMedium),
              if (video) ...[
                const SizedBox(height: 8),
                Text('It takes hours, and starts straight away.', style: t.bodyMedium?.copyWith(color: c.inkMuted)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: parts.isEmpty ? null : () => Navigator.pop(context, parts),
          child: const Text('Regenerate'),
        ),
      ],
    );
  }
}
