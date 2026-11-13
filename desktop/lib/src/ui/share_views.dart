// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Sharing to improve the models: the wording people agree to before
/// anything is sent, and the card on a game that says what has been sent
/// from it and lets it be withdrawn (docs/MAC-APP-PLAN.md, "Privacy").
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:osb_core/osb_core.dart';

import '../brand.dart';
import '../game_controller.dart';
import '../services.dart';

/// The approved wording, shared/consent/share-v1.md after its comment,
/// word for word (a test compares the two). A changed wording is a new
/// file and a new [shareConsentVersion], agreed again.
const shareConsentText = '''
# Share this to improve OpenSportsBall

To get better at mapping pitches, telling teams apart, finding the ball and
following the play, OpenSportsBall's models learn from real games. If you
agree, the app sends what you checked or labelled for this game:

- **Pitch check:** the empty-pitch panorama, the lines we fitted, and the
  points you marked.
- **Kit check:** small pictures of people on the pitch, grouped by kit, and
  your corrections.
- **Ball labels:** still frames from the game and where you marked the
  ball.
- **Must-see moments:** panoramas of the game at those moments and the boxes
  you drew.

These are pictures of the game, so **they show the players, who are often
children, and anyone else in view.** Share only if you are allowed to
record them (as you already agree when you record).

What happens to it:

- It is kept apart from your game's footage, and **it is not deleted when
  you delete the game or the recording**: that's what makes it useful for
  training.
- It is kept until you withdraw it or close your account, or until your
  account has gone unused for 3 years.
- It is used only to train and test OpenSportsBall's models, and seen only
  by the people who build them. It is not published or shared outside the
  project.
- You can withdraw anything you shared at any time, in the app or on the
  website (Account, Shared to improve OpenSportsBall), and closing your
  account withdraws all of it. A model already trained on it isn't undone.

[Read the privacy policy](https://opensportsball.com/privacy)
''';

/// One block of the wording: its heading, a paragraph, a bullet or a link.
typedef ConsentBlock = ({String kind, String text, String? url});

/// The wording's few kinds of Markdown: a `#` heading, paragraphs, `-`
/// bullets (continued on indented lines), `**bold**` and one link line.
List<ConsentBlock> consentBlocks(String markdown) {
  final out = <ConsentBlock>[];
  String? kind;
  final buf = <String>[];
  void flush() {
    if (kind != null && buf.isNotEmpty) out.add((kind: kind!, text: buf.join(' '), url: null));
    kind = null;
    buf.clear();
  }

  for (final line in markdown.split('\n')) {
    final link = RegExp(r'^\[(.+)\]\((https://[^)]+)\)$').firstMatch(line.trim());
    if (line.trim().isEmpty) {
      flush();
    } else if (link != null) {
      flush();
      out.add((kind: 'link', text: link[1]!, url: link[2]));
    } else if (line.startsWith('# ')) {
      flush();
      out.add((kind: 'heading', text: line.substring(2).trim(), url: null));
    } else if (line.startsWith('- ')) {
      flush();
      kind = 'bullet';
      buf.add(line.substring(2).trim());
    } else {
      kind ??= 'paragraph';
      buf.add(line.trim());
    }
  }
  flush();
  return out;
}

TextSpan _bold(String text, TextStyle? style) {
  final parts = text.split('**');
  return TextSpan(
    style: style,
    children: [
      for (var i = 0; i < parts.length; i++)
        TextSpan(
          text: parts[i],
          style: i.isOdd ? const TextStyle(fontWeight: FontWeight.w700) : null,
        ),
    ],
  );
}

/// The wording, laid out.
class ConsentBody extends StatelessWidget {
  const ConsentBody({super.key, this.heading = true});

  /// Leave the heading out where the screen has its own.
  final bool heading;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in consentBlocks(shareConsentText))
          switch (b.kind) {
            'heading' =>
              heading
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(b.text, style: t.titleLarge),
                    )
                  : const SizedBox.shrink(),
            'bullet' => Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: t.bodyMedium),
                  Expanded(child: Text.rich(_bold(b.text, t.bodyMedium))),
                ],
              ),
            ),
            'link' => Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => openFile(b.url!), child: Text(b.text)),
            ),
            _ => Padding(padding: const EdgeInsets.only(bottom: 10), child: Text.rich(_bold(b.text, t.bodyMedium))),
          },
      ],
    );
  }
}

/// Shows the wording; true when the user agreed (which is then kept in
/// Settings, for every game).
Future<bool> showShareConsent(BuildContext context, Settings settings) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: const SizedBox(width: 600, child: SingleChildScrollView(child: ConsentBody())),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('I agree')),
      ],
    ),
  );
  if (agreed != true) return false;
  await settings.setSharingAgreed(true);
  return true;
}

/// What a contribution is called on screen.
String sharedName(String name) => switch (name) {
  'pitch' => 'the pitch map',
  'kits' => 'the kit groups', // sent by games checked before the kit check was removed
  _ when name.startsWith('ball-') => 'ball marks',
  _ when name.startsWith('moments-') => 'must-see moments',
  _ => name,
};

String _list(List<String> names) {
  final said = <String>[];
  for (final n in names.map(sharedName)) {
    if (!said.contains(n)) said.add(n);
  }
  if (said.length < 2) return said.join();
  return '${said.sublist(0, said.length - 1).join(', ')} and ${said.last}';
}

/// On a game, once its checks are answered: asks to share, says what is
/// being sent or has been, and withdraws it.
class ShareCard extends StatelessWidget {
  const ShareCard({super.key, required this.controller});
  final GameController controller;

  @override
  Widget build(BuildContext context) {
    final ctl = controller;
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final muted = t.bodyMedium?.copyWith(color: c.inkMuted);
    final String title;
    final List<Widget> body;
    if (!ctl.settings.sharingAgreed) {
      title = 'Help OpenSportsBall get better';
      body = [
        Text(
          'Share what you checked for this game (the pitch map, where you left its switch on) so the next version '
          'maps pitches better. Nothing is sent until you agree.',
          style: muted,
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: () async {
            if (await showShareConsent(context, ctl.settings)) unawaited(ctl.sendAgreed());
          },
          child: const Text('Read what is shared'),
        ),
      ];
    } else if (ctl.shareStopped) {
      title = 'Withdrawn';
      body = [
        Text('What this game shared was deleted, and nothing more is sent from it.', style: muted),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: ctl.shareAgain, child: const Text('Share this game again')),
      ];
    } else if (ctl.sending case final s?) {
      title = 'Sharing ${sharedName(s.name)}';
      body = [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: s.files == 0 ? null : s.filesDone / s.files, minHeight: 6),
        ),
        const SizedBox(height: 6),
        Text('${s.filesDone} of ${s.files} files', style: muted),
      ];
    } else if (ctl.shareError != null) {
      title = 'Not shared yet';
      body = [
        Text('${ctl.shareError} It is tried again the next time this game is opened.', style: muted),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: ctl.sendAgreed, child: const Text('Try again')),
      ];
    } else if (ctl.sharedNames.isEmpty) {
      return const SizedBox.shrink(); // agreed; nothing of this game is shared (its switches are off)
    } else {
      title = 'Shared to improve OpenSportsBall';
      body = [
        Text('From this game: ${_list(ctl.sharedNames)}. Thank you.', style: muted),
        const SizedBox(height: 6),
        TextButton(
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
          onPressed: () async {
            final sure = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Withdraw what this game shared?'),
                content: const SizedBox(
                  width: 440,
                  child: Text(
                    'It is deleted from the project for good, and nothing more is sent from this game. A model '
                    'already trained on it isn’t undone.',
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep sharing')),
                  FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Withdraw')),
                ],
              ),
            );
            if (sure == true) await ctl.withdrawShared();
          },
          child: const Text('Withdraw'),
        ),
      ];
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(BrandRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.titleSmall),
          const SizedBox(height: 6),
          ...body,
        ],
      ),
    );
  }
}
