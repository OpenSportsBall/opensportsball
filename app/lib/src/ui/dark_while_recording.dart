// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/material.dart';

/// Blacks out the screen [delay] after recording starts, to save battery
/// and heat over a whole game. The screen can't actually turn off (the OS
/// would take the camera away), so this shows black at minimum brightness,
/// which on OLED phones is close to off, and stops drawing the preview.
///
/// A tap wakes the normal screen for [delay], then it darkens again. Only
/// the tap is consumed while dark, so a stray touch can't press a button.
class DarkWhileRecording extends StatefulWidget {
  const DarkWhileRecording({
    super.key,
    required this.enabled,
    required this.recording,
    required this.camera,
    required this.status,
    required this.child,
    this.delay = const Duration(seconds: 15),
  });

  /// The user setting; when false this does nothing.
  final bool enabled;
  final bool recording;
  final DualCamera camera;

  /// The one line shown while dark, e.g. "REC 00:41:12 · Secondary OK".
  final String Function() status;
  final Widget child;
  final Duration delay;

  @override
  State<DarkWhileRecording> createState() => DarkWhileRecordingState();
}

class DarkWhileRecordingState extends State<DarkWhileRecording> {
  Timer? _dimTimer;
  Timer? _tick;
  bool _dark = false;
  late final AppLifecycleListener _lifecycle;

  bool get dark => _dark;

  bool get _active => widget.enabled && widget.recording;

  @override
  void initState() {
    super.initState();
    // iOS hands brightness back when the app leaves the foreground; put the
    // dark level back on return.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (_dark) unawaited(widget.camera.setScreenBrightness(0.01));
    });
    _sync();
  }

  @override
  void didUpdateWidget(DarkWhileRecording oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled || oldWidget.recording != widget.recording) _sync();
  }

  void _sync() {
    if (_active) {
      if (!_dark && _dimTimer == null) _schedule();
    } else {
      _wake(reschedule: false);
    }
  }

  void _schedule() {
    _dimTimer?.cancel();
    _dimTimer = Timer(widget.delay, _darken);
  }

  void _darken() {
    _dimTimer = null;
    if (!_active || !mounted) return;
    setState(() => _dark = true);
    unawaited(widget.camera.setScreenBrightness(0.01));
    unawaited(widget.camera.setPreviewPaused(true));
    // Refresh the status line, and move it, once a minute.
    _tick = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });
  }

  void _wake({required bool reschedule}) {
    _dimTimer?.cancel();
    _dimTimer = null;
    _tick?.cancel();
    _tick = null;
    if (_dark) {
      unawaited(widget.camera.setScreenBrightness(null));
      unawaited(widget.camera.setPreviewPaused(false));
      if (mounted) setState(() => _dark = false);
    }
    if (reschedule && _active) _schedule();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _dimTimer?.cancel();
    _tick?.cancel();
    if (_dark) {
      unawaited(widget.camera.setScreenBrightness(null));
      unawaited(widget.camera.setPreviewPaused(false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Any touch while awake pushes the darkening back.
      onPointerDown: (_) {
        if (!_dark && _active) _schedule();
      },
      child: Stack(
        children: [
          widget.child,
          if (_dark) Positioned.fill(child: _DarkOverlay(status: widget.status(), onWake: () => _wake(reschedule: true))),
        ],
      ),
    );
  }
}

class _DarkOverlay extends StatelessWidget {
  const _DarkOverlay({required this.status, required this.onWake});

  final String status;
  final VoidCallback onWake;

  @override
  Widget build(BuildContext context) {
    // Drift the text around a 3x3 grid, one step a minute, so no pixels
    // stay lit for the whole game.
    final step = DateTime.now().minute % 9;
    final align = Alignment(-0.8 + 0.8 * (step % 3), -0.8 + 0.8 * (step ~/ 3));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onWake,
      child: ColoredBox(
        color: Colors.black,
        child: Align(
          alignment: align,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: Color(0xFF7A1F1F), shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(status, style: const TextStyle(color: Color(0xFF5A5A5A), fontSize: 14)),
              ]),
              const SizedBox(height: 4),
              const Text('Recording. Tap to show the screen.',
                  style: TextStyle(color: Color(0xFF3A3A3A), fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
