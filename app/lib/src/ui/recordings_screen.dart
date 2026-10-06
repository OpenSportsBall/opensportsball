// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../role.dart';
import '../storage/store.dart';
import 'common.dart';

/// Recordings on this phone, with sharing so test footage can be copied off
/// (AirDrop, Files, Drive) until cloud upload exists.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key, required this.store});
  final AppStore store;
  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  late Future<List<StoredRecording>> _list = widget.store.listRecordings();

  void _reload() => setState(() => _list = widget.store.listRecordings());

  Future<void> _share(StoredRecording r, {bool withManifest = true}) async {
    final files = [
      ...r.segmentFiles.where((f) => f.existsSync()).map((f) => f.path),
      if (withManifest && r.hasManifest) '${r.dir.path}/manifest.json',
      '${r.dir.path}/recording.json',
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
    if (rec.peer == null) return 'this phone only';
    return r.hasManifest ? 'manifest ready' : 'waiting for Secondary segments';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recordings')),
      body: FutureBuilder(
        future: _list,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('No recordings yet.'));
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = list[i];
              final rec = r.recording;
              final created = DateTime.fromMillisecondsSinceEpoch(rec.createdAtMs);
              return ExpansionTile(
                title: Text('${_date(created)}  ·  ${rec.role.label}'),
                subtitle: Text('${rec.segments.length} segments · ${formatBytes(r.totalBytes)} · ${_status(r)}'),
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
          );
        },
      ),
    );
  }

  String _date(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
