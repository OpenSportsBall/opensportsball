// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Asked only when the two phones' views couldn't be stitched: the
/// panorama drawn both ways round; the right one shows the pitch in one
/// piece.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:osb_core/osb_core.dart';

import '../brand.dart';
import '../game_controller.dart';

class CamerasCheck extends StatelessWidget {
  const CamerasCheck({super.key, required this.controller, required this.question});
  final GameController controller;
  final CamerasQuestion question;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final folder = controller.folder!.path;
    Widget option(String image, String caption, bool mainLeft) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(BrandRadius.sm)),
              clipBehavior: Clip.antiAlias,
              child: Image.file(File('$folder/$image'), fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            child: FilledButton.tonal(
              onPressed: controller.busy
                  ? null
                  : () => controller.answer((a) => a.answerCameras(question.round, mainLeft: mainLeft)),
              child: Text(caption),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Which phone filmed the left side?', style: t.titleLarge),
          const SizedBox(height: 4),
          Text(
            'We couldn’t match the two phones’ views by themselves${question.reason == null ? '' : ' (${question.reason})'}. '
            'Here is the pitch drawn both ways round: choose the one that shows it in one piece.',
            style: t.bodyMedium?.copyWith(color: c.inkMuted),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                option(question.mainLeft, 'This one: Main on the left', true),
                const SizedBox(height: 18),
                option(question.secondaryLeft, 'This one: Secondary on the left', false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
