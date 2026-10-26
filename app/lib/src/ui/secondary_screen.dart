// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../link/ble_link.dart';
import '../link/peer_link.dart';
import '../session/secondary_controller.dart';
import '../storage/store.dart';
import '../upload/account.dart';
import 'common.dart';
import 'dark_while_recording.dart';

/// Scans Main's pairing code, then hands the camera over to the recorder.
class SecondaryScreen extends StatefulWidget {
  const SecondaryScreen({super.key, required this.store, required this.account});
  final AppStore store;
  final AccountManager account;
  @override
  State<SecondaryScreen> createState() => _SecondaryScreenState();
}

class _SecondaryScreenState extends State<SecondaryScreen> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _scannerReleased = false;
  String? _gameId;
  String? _scanError;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_gameId != null) return;
    for (final code in capture.barcodes) {
      final game = code.rawValue == null ? null : parsePairingUri(code.rawValue!);
      if (game == null) {
        setState(() => _scanError = 'That is not a OpenSportsBall pairing code.');
        continue;
      }
      _gameId = game;
      // The scanner holds the camera; release it before recording opens it.
      await _scanner.stop();
      await _scanner.dispose();
      _scannerReleased = true;
      if (mounted) setState(() {});
      return;
    }
  }

  @override
  void dispose() {
    if (!_scannerReleased) _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final game = _gameId;
    if (game != null && _scannerReleased) {
      return _SecondarySession(store: widget.store, account: widget.account, gameId: game);
    }
    return Scaffold(
      body: PreviewLayout(
        preview: game == null
            ? MobileScanner(controller: _scanner, onDetect: _onDetect)
            : const CircularProgressIndicator(),
        panel: [
          const Row(children: [BackButton(), Text('Secondary phone')]),
          const SizedBox(height: 16),
          const Text('Point this phone at the QR code on the Main phone.'),
          const SizedBox(height: 12),
          ErrorText(_scanError),
        ],
      ),
    );
  }
}

class _SecondarySession extends StatefulWidget {
  const _SecondarySession({required this.store, required this.account, required this.gameId});
  final AppStore store;
  final AccountManager account;
  final String gameId;
  @override
  State<_SecondarySession> createState() => _SecondarySessionState();
}

class _SecondarySessionState extends State<_SecondarySession> {
  final _camera = DualCamera();
  late final SecondaryController c = SecondaryController(
    store: widget.store,
    camera: _camera,
    gameId: widget.gameId,
    linkFactory: (gameId) => SecondaryBleLink(gameId: gameId, ensurePermission: _camera.requestBluetoothPermission),
    account: widget.account,
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

  bool get _recording =>
      c.phase == SecondaryPhase.recording || c.phase == SecondaryPhase.stopping;

  Future<void> _stopLocally() async {
    if (await confirm(
        context,
        'Stop recording on this phone?',
        'Normally the Main phone stops both. Use this if the Main phone is out '
            'of range or the game is over.',
        'Stop')) {
      await c.stopLocally();
    }
  }

  Widget _darkened(Widget child) => DarkWhileRecording(
        // Main's setting wins once paired.
        enabled: c.welcome?.settings.darkenScreen ?? widget.store.settings.darkenScreen,
        recording: c.phase == SecondaryPhase.recording,
        camera: c.recorder.camera,
        status: () {
          final started = c.current?.startedAtDeviceMs;
          final elapsed = started == null
              ? ''
              : formatElapsed(DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(started)));
          return 'REC $elapsed · ${c.connected ? 'Main OK' : 'Main out of range'}';
        },
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => _darkened(PopScope(
        canPop: !_recording,
        child: Scaffold(
          body: PreviewLayout(
            preview: c.phase == SecondaryPhase.noCamera
                ? NoCameraPreview(onRetry: c.retryCamera)
                : c.opened == null
                    ? const Text('Camera opens once connected to the Main phone.',
                        style: TextStyle(color: Colors.white))
                    : DualCameraPreview(opened: c.opened!),
            panel: [
              Row(children: [
                if (!_recording) const BackButton(),
                Text('Secondary phone', style: Theme.of(context).textTheme.titleLarge),
              ]),
              const SizedBox(height: 8),
              ErrorText(c.error),
              _connectionSection(),
              _recordingSection(),
              if (!_recording && c.phase == SecondaryPhase.ready)
                Text('Ready. The Main phone starts and stops recording.',
                    style: Theme.of(context).textTheme.bodyMedium),
            ],
            footer: _recording
                ? RecordButton(
                    recording: true,
                    busy: c.phase == SecondaryPhase.stopping,
                    onPressed: _stopLocally,
                    stopLabel: 'Stop on this phone',
                  )
                : null,
          ),
        ),
      )),
    );
  }

  Widget _connectionSection() {
    return ValueListenableBuilder(
      valueListenable: c.link.problem,
      builder: (context, problem, _) => PanelSection(title: 'Main phone', children: [
        InfoRow(
          'Bluetooth',
          problem ??
              switch (c.link.state.value) {
                LinkState.connected => 'connected',
                LinkState.connecting => 'connecting…',
                LinkState.searching => 'searching…',
                _ => 'starting…',
              },
          warn: problem != null || (_recording && !c.connected),
        ),
        if (_recording && !c.connected)
          const Text('Lost contact with the Main phone. Still recording.'),
        if (c.clock != null)
          InfoRow('Clock offset',
              '${c.clock!.secondaryOffsetMs.toStringAsFixed(0)} ms (±${(c.clock!.medianRttMs / 2).toStringAsFixed(0)})'),
        InfoRow(
            'Uploads',
            c.grant != null
                ? 'to the Main phone\'s account'
                : 'waiting for permission from the Main phone',
            warn: c.grant == null && c.connected),
        ErrorText(c.grantError),
      ]),
    );
  }

  Widget _recordingSection() {
    final rec = c.current;
    final o = c.opened;
    return Ticker(
      builder: (context) => PanelSection(title: 'This phone', children: [
        if (o != null)
          InfoRow('Video', '${o.width}×${o.height} ${o.fps} fps ${o.codec.name.toUpperCase()}'),
        if (rec != null && !rec.stopped && rec.startedAtDeviceMs != null)
          InfoRow('Elapsed', formatElapsed(DateTime.now()
              .difference(DateTime.fromMillisecondsSinceEpoch(rec.startedAtDeviceMs!)))),
        if (rec != null) InfoRow('Segments', '${rec.segments.length}'),
      ]),
    );
  }
}
