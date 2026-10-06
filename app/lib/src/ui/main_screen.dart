// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../link/ble_link.dart';
import '../link/peer_link.dart';
import '../session/main_controller.dart';
import '../storage/store.dart';
import 'common.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, required this.store});
  final AppStore store;
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late final MainController c = MainController(
    store: widget.store,
    camera: DualCamera(),
    linkFactory: (gameId) => MainBleLink(gameId: gameId),
  );

  @override
  void initState() {
    super.initState();
    c.init();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  bool get _recording => c.phase == MainPhase.recording || c.phase == MainPhase.stopping;

  Future<void> _start() async {
    if (!c.secondaryConnected) {
      final alone = await confirm(context, 'Secondary not connected',
          'Record on this phone only?', 'Record alone');
      if (alone) await c.startRecording(alone: true);
      return;
    }
    final ok = await c.startRecording();
    if (!ok && mounted && c.phase == MainPhase.idle) {
      final alone = await confirm(context, 'Secondary is not ready',
          '${c.error ?? ''}\n\nRecord on this phone only?', 'Record alone');
      if (alone) await c.startRecording(alone: true);
    }
  }

  Future<void> _stop() async {
    if (await confirm(context, 'Stop recording?', 'Both phones will stop.', 'Stop')) {
      await c.stopRecording();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => PopScope(
        canPop: !_recording,
        child: Scaffold(
          body: SafeArea(
            child: PreviewLayout(
              preview: c.opened == null
                  ? const Text('Opening camera…', style: TextStyle(color: Colors.white))
                  : DualCameraPreview(opened: c.opened!),
              panel: [
                Row(children: [
                  if (!_recording) const BackButton(),
                  Text('Main phone', style: Theme.of(context).textTheme.titleLarge),
                ]),
                const SizedBox(height: 8),
                ErrorText(c.error),
                _secondarySection(context),
                _recordingSection(),
                _thisPhoneSection(),
                RecordButton(
                  recording: _recording,
                  busy: c.phase == MainPhase.preparing ||
                      c.phase == MainPhase.stopping ||
                      c.phase == MainPhase.starting,
                  onPressed: _recording ? _stop : _start,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _secondarySection(BuildContext context) {
    final link = c.link;
    if (!c.secondaryConnected) {
      return PanelSection(title: 'Pair the Secondary phone', children: [
        Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            child: QrImageView(data: pairingUri(c.gameId), size: 168),
          ),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder(
          valueListenable: link.problem,
          builder: (context, problem, _) => Text(
            problem ??
                switch (link.state.value) {
                  LinkState.advertising => 'Waiting for the Secondary phone to scan this code.',
                  LinkState.connected => 'Connected. Waiting for the Secondary phone…',
                  _ => 'Starting Bluetooth…',
                },
            textAlign: TextAlign.center,
          ),
        ),
      ]);
    }
    final s = c.secondaryStatus;
    return Ticker(
      builder: (context) => PanelSection(title: 'Secondary phone', children: [
        InfoRow('Model', c.secondary!.model),
        if (c.secondaryStale) const InfoRow('Contact', 'no heartbeat', warn: true),
        if (s != null) ...[
          InfoRow('Battery', '${s.batteryPercent}%${s.charging ? ' (charging)' : ''}',
              warn: s.batteryPercent < 20 && !s.charging),
          InfoRow('Free storage', formatBytes(s.freeStorageBytes),
              warn: s.freeStorageBytes < 10 * 1024 * 1024 * 1024),
          InfoRow('Temperature', s.thermalState,
              warn: s.thermalState == 'serious' || s.thermalState == 'critical'),
          InfoRow('Recording', s.recording ? formatElapsed(Duration(milliseconds: s.elapsedMs)) : 'no',
              warn: _recording && !s.recording),
          if (s.recording || s.segmentCount > 0) InfoRow('Segments', '${s.segmentCount}'),
        ],
        if (c.clock != null)
          InfoRow('Clock offset',
              '${c.clock!.secondaryOffsetMs.toStringAsFixed(0)} ms (±${(c.clock!.medianRttMs / 2).toStringAsFixed(0)})'),
      ]),
    );
  }

  Widget _recordingSection() {
    final rec = c.current;
    if (rec == null) return const SizedBox.shrink();
    final peer = rec.peer;
    return Ticker(
      builder: (context) => PanelSection(title: 'Recording', children: [
        if (!rec.stopped && rec.startedAtDeviceMs != null)
          InfoRow('Elapsed', formatElapsed(DateTime.now()
              .difference(DateTime.fromMillisecondsSinceEpoch(rec.startedAtDeviceMs!)))),
        InfoRow('Segments (this phone)', '${rec.segments.length}'),
        if (peer != null)
          InfoRow('Segments (Secondary)',
              '${peer.segments.length}${peer.expectedSegments != null ? ' of ${peer.expectedSegments}' : ''}'),
        if (rec.stopped)
          InfoRow(
            'Manifest',
            c.manifestsWritten.contains(rec.recordingId)
                ? (peer == null ? 'ready (this phone only)' : 'ready')
                : 'waiting for Secondary',
            warn: !c.manifestsWritten.contains(rec.recordingId),
          ),
      ]),
    );
  }

  Widget _thisPhoneSection() {
    final s = c.ownStatus;
    final o = c.opened;
    return PanelSection(title: 'This phone', children: [
      if (o != null) ...[
        InfoRow('Video', '${o.width}×${o.height} ${o.fps} fps ${o.codec.name.toUpperCase()}'),
        InfoRow('Lens', '${o.lens.name}${o.horizontalFovDeg != null ? ', ${o.horizontalFovDeg!.toStringAsFixed(0)}°' : ''}'),
      ],
      if (s != null) ...[
        InfoRow('Battery', '${s.batteryPercent}%${s.charging ? ' (charging)' : ''}',
            warn: s.batteryPercent < 20 && !s.charging),
        InfoRow('Free storage', formatBytes(s.freeStorageBytes),
            warn: s.freeStorageBytes < 10 * 1024 * 1024 * 1024),
        InfoRow('Temperature', s.thermalState.name,
            warn: s.thermalState.index >= ThermalState.serious.index),
      ],
    ]);
  }
}
