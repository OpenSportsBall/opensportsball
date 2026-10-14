// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../upload/account.dart';
import '../upload/network.dart';
import '../upload/upload_service.dart';
import 'account_screen.dart';
import 'common.dart';

/// Upload queue status and controls. Uploads run while the app is open.
class UploadsScreen extends StatefulWidget {
  const UploadsScreen({super.key, required this.uploads, required this.account});
  final UploadService uploads;
  final AccountManager account;
  @override
  State<UploadsScreen> createState() => _UploadsScreenState();
}

class _UploadsScreenState extends State<UploadsScreen> {
  UploadService get u => widget.uploads;

  @override
  void initState() {
    super.initState();
    u.refresh();
    u.kick();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([u, widget.account]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final total = u.pendingBytesTotal, done = u.pendingBytesDone;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Uploads'),
            actions: [
              TextButton.icon(
                onPressed: () => u.setPaused(!u.paused),
                icon: Icon(u.paused ? Icons.play_arrow : Icons.pause),
                label: Text(u.paused ? 'Resume' : 'Pause'),
              ),
            ],
          ),
          body: SafeArea(child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              AccountBanner(account: widget.account),
              PanelSection(title: 'Status', children: [
                InfoRow('Queue', u.phase.label,
                    warn: u.phase == UploadPhase.unlinked ||
                        u.phase == UploadPhase.failed ||
                        u.phase == UploadPhase.grantExpired),
                InfoRow('Network', switch (u.networkKind) {
                  NetworkKind.unmetered => 'Wi-Fi',
                  NetworkKind.metered => 'Mobile data',
                  NetworkKind.offline => 'None',
                }),
                if (u.error != null) InfoRow('Last problem', u.error!, warn: true),
                if (u.retryAt != null)
                  InfoRow('Next try', TimeOfDay.fromDateTime(u.retryAt!).format(context)),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: total == 0 ? 1 : done / total),
                const SizedBox(height: 4),
                Text(
                  total == 0
                      ? 'Nothing waiting to upload.'
                      : '${formatBytes(done)} of ${formatBytes(total)} uploaded '
                          '(${u.pending.length} recording${u.pending.length == 1 ? '' : 's'} waiting)',
                  style: theme.textTheme.bodySmall,
                ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Upload on Wi-Fi only'),
                subtitle: const Text('Recordings are large: about 16 GB per hour at 4K.'),
                value: u.wifiOnly,
                onChanged: (v) => u.setWifiOnly(v),
              ),
              if (u.blockedByMobileData)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: () => _confirmMobileData(context),
                    icon: const Icon(Icons.signal_cellular_alt),
                    label: const Text('Upload now using mobile data'),
                  ),
                ),
              if (u.mobileOverride && u.wifiOnly)
                Row(children: [
                  const Expanded(child: Text('Using mobile data until the queue is empty.')),
                  TextButton(onPressed: u.cancelMobileData, child: const Text('Stop')),
                ]),
              const SizedBox(height: 16),
              Text('Recordings on this phone', style: theme.textTheme.titleSmall),
              if (u.recordings.isEmpty) const Text('None yet.'),
              for (final r in u.recordings.reversed) _RecordingTile(r),
            ],
          )),
        );
      },
    );
  }

  Future<void> _confirmMobileData(BuildContext context) async {
    final total = u.pendingBytesTotal - u.pendingBytesDone;
    if (await confirm(context, 'Use mobile data?',
        'About ${formatBytes(total)} will be uploaded over mobile data. This may cost money on your plan.',
        'Upload now')) {
      u.useMobileDataOnce();
    }
  }
}

class _RecordingTile extends StatelessWidget {
  const _RecordingTile(this.r);
  final RecordingUpload r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rec = r.recording;
    final created = DateTime.fromMillisecondsSinceEpoch(rec.createdAtMs);
    final String status;
    if (!rec.stopped) {
      status = 'not finished';
    } else if (r.complete) {
      status = 'uploaded';
    } else {
      status = '${r.filesDone} of ${r.filesTotal} files uploaded';
    }
    final what = r.isMain ? 'manifest' : 'segment list';
    final manifest = !rec.stopped
        ? null
        : r.manifestUploaded
            ? '$what uploaded'
            : '$what not uploaded';
    final current = r.currentFile;
    // Secondary footage goes to the Main phone's account (its grant).
    final where = r.target?.grant == true ? 'to the Main phone\'s account' : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(
              r.complete ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
              size: 20,
              color: r.complete ? theme.colorScheme.primary : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  '${_date(created)} · ${rec.role.label} · ${formatBytes(r.bytesTotal)}'),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text([status, if (manifest != null) manifest, if (where != null) where].join(' · '),
                    style: theme.textTheme.bodySmall),
                if (rec.stopped && !r.complete && r.blocked != null)
                  Text(r.blocked!.label,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                if (current != null && r.currentFileBytes > 0) ...[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: r.currentFileSent / r.currentFileBytes),
                  Text(
                    '$current: ${formatBytes(r.currentFileSent)} of ${formatBytes(r.currentFileBytes)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (r.error != null)
                  Text(r.error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Not linked" / "unlinked" prompt with a button to the account screen.
/// Shows nothing while the phone is linked.
class AccountBanner extends StatelessWidget {
  const AccountBanner({super.key, required this.account});
  final AccountManager account;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) {
        if (!account.loaded || (account.linked && !account.revoked)) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        return Card(
          color: scheme.secondaryContainer,
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Icon(Icons.link),
              const SizedBox(width: 12),
              Expanded(
                child: Text(account.revoked
                    ? 'This phone was unlinked; link it again to upload.'
                    : 'Link this phone to your account to upload recordings.'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => AccountScreen(account: account))),
                child: const Text('Link to account'),
              ),
            ]),
          ),
        );
      },
    );
  }
}

String _date(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
