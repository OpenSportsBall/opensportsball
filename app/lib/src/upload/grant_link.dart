// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Upload permission links (docs/API.md): a phone that recorded a game as
/// Secondary but never got a grant from Main (Main was not linked) gets one
/// later from the website, as a link opened on this phone.
library;

import '../role.dart';
import '../storage/store.dart';
import 'account.dart';
import 'upload_service.dart';

/// What opening a link did, for a dialog.
class GrantLinkResult {
  const GrantLinkResult(this.title, this.message);
  final String title;
  final String message;
}

/// Applies the upload permission link [raw] to this phone's recording of
/// its game, then wakes the upload queue.
Future<GrantLinkResult> openGrantLink(
  String raw, {
  required AppStore store,
  required AccountManager account,
  required UploadService uploads,
  DateTime Function() now = DateTime.now,
}) async {
  final ticket = parseGrantUri(raw);
  if (ticket == null) {
    return const GrantLinkResult('Link not recognised',
        'This upload permission link is not complete. Copy it again from the game\'s page on the website.');
  }
  final me = store.identity.deviceId;
  final recordings = await store.listRecordings();
  final mine = recordings.any((s) =>
      s.recording.device.deviceId == me &&
      s.recording.gameId == ticket.gameId &&
      s.recording.role == DeviceRole.secondary);
  // Checked before redeeming: a phone without footage of that game must
  // not use up the link meant for the one that has it.
  if (!mine) {
    return const GrantLinkResult('No recording of that game',
        'This phone has no Secondary recording of that game. Open the link on the phone that recorded it.');
  }
  final current = await account.grantFor(ticket.gameId);
  if (current != null && !current.unredeemed && current.usableAt(now())) {
    uploads.kick();
    return const GrantLinkResult('Already allowed',
        'This phone already has upload permission for that game. Its footage uploads from the Uploads screen.');
  }
  if (!now().isBefore(ticket.expiresAt)) {
    return const GrantLinkResult('Link expired', 'Ask for a new link from the game\'s page on the website.');
  }
  try {
    final bound = await account.acceptGrantLink(ticket, deviceId: me);
    uploads.kick();
    return bound
        ? const GrantLinkResult('Upload permission added',
            'This phone\'s footage of that game now uploads to the account that sent the link. See the Uploads screen.')
        : const GrantLinkResult('Upload permission saved',
            'No internet right now. The footage uploads to the account that sent the link once this phone is online.');
  } on LinkException catch (e) {
    return GrantLinkResult('Could not use this link', e.message);
  }
}
