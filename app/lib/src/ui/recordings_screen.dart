// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../role.dart';
import '../storage/store.dart';
import '../upload/account.dart';
import '../upload/upload_service.dart';
import 'common.dart';
import 'uploads_screen.dart';

/// Recordings on this phone, with sharing so test footage can be copied off
/// (AirDrop, Files, Drive) as well as uploading.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({
    super.key,
    required this.store,
    required this.account,
    required this.uploads,
  });
  final AppStore store;
  final AccountManager account;
  final UploadService uploads;
  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  late Future<List<StoredRecording>> _list = widget.store.listRecordings();

  void _reload() => setState(() => _list = widget.store.listRecordings());

  Future<void> _share(StoredRecording r, {bool withManifest = true}) async {
    final files = [
      ...r.segmentFiles.where((f) => f.existsSync()).map((f) => f.path),
      if (withManifest && r.hasDocument) '${r.dir.path}/${r.documentName}',
      '${r.dir.path}/recording.json',
      if (File('${r.dir.path}/power.csv').existsSync()) '${r.dir.path}/power.csv',
    ];
    await SharePlus.instance.share(ShareParams(files: [for (final p in files) XFile(p)]));
  }

  Future<void> _delete(StoredRecording r) async {
    if (await confirm(context, 'Delete this recording?',
        'Deletes ${r.recording.segments.length} files (${formatBytes(r.totalBytes)}) from this phone.',
        'Delete')) {
      await widget.store.deleteRecording(r);
      _reload();
    }
  }

  String _status(StoredRecording r) {
    final rec = r.recording;
    if (!rec.stopped) return 'not finished';
    if (rec.endReason != null) return 'ended early: ${rec.endReason}';
    if (rec.role == DeviceRole.secondary) return 'recorded as Secondary';
    if (!r.hasDocument) return 'no manifest yet';
    return rec.peer == null ? 'manifest ready (this phone only)' : 'manifest ready';
  }

  String? _uploadStatus(StoredRecording r) {
    for (final u in widget.uploads.recordings) {
      if (u.stored.dir.path != r.dir.path) continue;
      if (u.complete) return 'uploaded';
      if (u.blocked != null) return null; // not linked / no grant: the banner or Uploads says why
      if (u.error != null) return 'upload problem';
      return '${u.filesDone}/${u.filesTotal} uploaded';
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    widget.uploads.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(
            tooltip: 'Uploads',
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => UploadsScreen(uploads: widget.uploads, account: widget.account))),
          ),
        ],
      ),
      body: SafeArea(child: FutureBuilder(
        future: _list,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          final banner = Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: AccountBanner(account: widget.account),
          );
          if (list.isEmpty) {
            return Column(children: [
              banner,
              const Expanded(child: Center(child: Text('No recordings yet.'))),
            ]);
          }
          return ListenableBuilder(
            listenable: widget.uploads,
            builder: (context, _) => ListView.separated(
              itemCount: list.length + 1,
              separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == 0) return banner;
                final r = list[i - 1];
                final rec = r.recording;
                final created = DateTime.fromMillisecondsSinceEpoch(rec.createdAtMs);
                final upload = _uploadStatus(r);
                return ExpansionTile(
                  title: Text('${_date(created)}  ·  ${rec.role.label}'),
                  subtitle: Text('${rec.segments.length} segments · ${formatBytes(r.totalBytes)} · ${_status(r)}'
                      '${upload == null ? '' : ' · $upload'}'),
                  children: [
                    for (final s in rec.segments)
                      ListTile(
                        dense: true,
                        title: Text(s.fileName),
                        subtitle: Text('${formatElapsed(Duration(milliseconds: s.durationMs))} · ${formatBytes(s.bytes)}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.ios_share),
                          onPressed: () => SharePlus.instance.share(ShareParams(
                              files: [XFile('${r.dir.path}${Platform.pathSeparator}${s.fileName}')])),
                        ),
                      ),
                    OverflowBar(
                      alignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: () => _delete(r),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: rec.segments.isEmpty ? null : () => _share(r),
                          icon: const Icon(Icons.ios_share),
                          label: const Text('Share all'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          );
        },
      )),
    );
  }

  String _date(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
