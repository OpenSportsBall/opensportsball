// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// A game whose video isn't all in the account: asking the phone that has
/// it to send it (an upload-permission link, as the website's game page
/// gives), or taking it from folders copied off the phones onto this Mac.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:osb_core/osb_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../brand.dart';
import '../game_controller.dart';
import '../services.dart';
import 'game_pane.dart';
import 'games_screen.dart';

/// What to choose, said where the folders are asked for.
const footageFolderHelp =
    'Choose the game’s folder as copied off each phone: the one holding manifest.json (the main phone) or '
    'report.json (the second phone) beside that phone’s video files. On an iPhone it is in Files, under '
    'OpenSportsBall, in recordings; on an Android phone, over USB, in the app’s files.';

/// Says a phone's video is still missing and asks for its folder too.
/// Returns the folders chosen, or null when the user gave up.
Future<List<String>?> askForMissingPhone(BuildContext context, PhoneMissing missing) async {
  final again = await showDialog<bool>(
    context: context,
    builder: (context) {
      final t = Theme.of(context).textTheme;
      return AlertDialog(
        title: Text(
          missing.role == 'main' ? 'The main phone’s video is needed too' : 'The second phone’s video is needed too',
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The engine stitches the two phones’ views into one, so it needs both. '
                '${missing.role == 'main' ? 'The folder chosen has no manifest.json from the main phone.' : 'The folder chosen has no video from the second phone${missing.model == null ? '' : ' (the ${missing.model})'}.'}',
                style: t.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(footageFolderHelp, style: t.bodySmall?.copyWith(color: BrandColors.of(context).inkMuted)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Choose its folder…')),
        ],
      );
    },
  );
  if (again != true) return null;
  final more = await pickFolders();
  return more.isEmpty ? null : more;
}

/// Adds video from folders on this Mac to [ctl]'s game: asks for the
/// folders ([folders] when already chosen), and for the other phone's when
/// one alone isn't the whole game.
Future<void> addVideoFromDisk(BuildContext context, GameController ctl, {List<String>? folders}) async {
  var chosen = folders ?? await pickFolders();
  while (chosen.isNotEmpty) {
    final missing = await ctl.addFromDisk(chosen);
    if (missing == null || !context.mounted) return;
    final more = await askForMissingPhone(context, missing);
    if (more == null) return;
    chosen = [...chosen, ...more];
  }
}

String _phone(RecordingDevice d) => d.model ?? (d.role == 'main' ? 'Main phone' : 'Second phone');

/// What has arrived from each phone, and the two ways to get the rest.
class MissingFootageCard extends StatelessWidget {
  const MissingFootageCard({super.key, required this.controller});
  final GameController controller;

  String _arrived(RecordingDevice d) {
    final got = d.uploadedBytes ?? 0, all = d.expectedBytes;
    if (all == null) return got == 0 ? 'nothing in your account yet' : '${formatGb(got)} in your account so far';
    if (got >= all) return 'all ${formatGb(all)} in your account';
    return got == 0
        ? 'nothing in your account yet (${formatGb(all)})'
        : '${formatGb(got)} of ${formatGb(all)} in your account';
  }

  @override
  Widget build(BuildContext context) {
    final ctl = controller;
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final r = ctl.recording!;
    final oneOnly = r.devices.length < 2 || !r.devices.any((d) => d.role == 'secondary');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          r.ready ? 'This game has video from one phone only.' : 'Not all of this game’s video is in your account.',
          style: t.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'The engine stitches the two phones’ views into one, so it needs both. A phone that is still uploading '
          'only needs the app open and Wi-Fi.',
          style: t.bodyMedium?.copyWith(color: c.inkMuted),
        ),
        const SizedBox(height: 12),
        for (final d in r.devices)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  d.expectedBytes != null && (d.uploadedBytes ?? 0) >= d.expectedBytes!
                      ? Icons.check_circle
                      : Icons.hourglass_bottom,
                  size: 18,
                  color: d.expectedBytes != null && (d.uploadedBytes ?? 0) >= d.expectedBytes! ? c.grass : c.sunText,
                ),
                const SizedBox(width: 8),
                Text('${_phone(d)}: ', style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                Flexible(child: Text(_arrived(d), style: t.bodyMedium)),
              ],
            ),
          ),
        if (oneOnly)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(Icons.cancel, size: 18, color: c.coral),
                const SizedBox(width: 8),
                Text(
                  r.devices.any((d) => d.role == 'main') ? 'Second phone: ' : 'Other phone: ',
                  style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Flexible(child: Text('nothing in your account', style: t.bodyMedium)),
              ],
            ),
          ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            if (ctl.sources.isNotEmpty)
              FilledButton.icon(
                onPressed: ctl.startDownload,
                icon: const Icon(Icons.folder_copy_outlined),
                label: const Text('Carry on adding the video'),
              ),
            OutlinedButton.icon(
              onPressed: () => showFootageRequest(context, ctl),
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Request footage from another phone'),
            ),
            OutlinedButton.icon(
              onPressed: () => addVideoFromDisk(context, ctl),
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Select video on this Mac…'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Request: a link for a phone that recorded this game but is waiting for upload permission. '
          'Select: the game’s folder copied off the phone. Video added from this Mac stays on this Mac; the website '
          'goes on showing the game as uploading.',
          style: t.bodySmall?.copyWith(color: c.inkMuted),
        ),
      ],
    );
  }
}

/// The upload-permission link for a phone that recorded this game without
/// one, as a QR code and to copy (the website's "Add footage from another
/// phone").
Future<void> showFootageRequest(BuildContext context, GameController ctl) => showDialog<void>(
  context: context,
  builder: (_) => _FootageRequest(controller: ctl),
);

class _FootageRequest extends StatefulWidget {
  const _FootageRequest({required this.controller});
  final GameController controller;

  @override
  State<_FootageRequest> createState() => _FootageRequestState();
}

class _FootageRequestState extends State<_FootageRequest> {
  GameTicket? _ticket;
  String? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _make();
  }

  Future<void> _make() async {
    setState(() => _error = null);
    final ctl = widget.controller;
    try {
      final t = await ctl.session.createGameTicket(ctl.summary.gameId);
      if (mounted) setState(() => _ticket = t);
    } on SignedOut {
      if (mounted) Navigator.pop(context);
      ctl.onSignedOut();
    } on OsbException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = BrandColors.of(context);
    final ticket = _ticket;
    final url = ticket?.pageUrl(widget.controller.session.config.siteUrl);
    return AlertDialog(
      title: const Text('Request footage from another phone'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null) ...[
              Text(_error!, style: t.bodyMedium?.copyWith(color: c.coral)),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _make, child: const Text('Try again')),
            ] else if (url == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              Text(
                'Open this link on the phone that recorded the game, or scan the code with its camera. Then tap '
                '“Open in the app”. It works for one phone.',
                style: t.bodyMedium,
              ),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(data: url, size: 220, padding: EdgeInsets.zero),
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(url, style: t.bodySmall?.copyWith(fontFamily: BrandFonts.mono)),
              const SizedBox(height: 8),
              Text(
                'Works until ${formatWhen(ticket!.expiresAt)}. Anyone with the link can use it. Once the phone has '
                'sent its video, press Refresh in the games list.',
                style: t.bodySmall?.copyWith(color: c.inkMuted),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (url != null)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (mounted) setState(() => _copied = true);
            },
            child: Text(_copied ? 'Copied' : 'Copy link'),
          ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
