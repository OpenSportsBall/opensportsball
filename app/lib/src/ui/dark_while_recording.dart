// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:dual_camera/dual_camera.dart';
import 'package:flutter/material.dart';

/// What the dark screen shows while recording.
class DarkStatus {
  const DarkStatus({required this.elapsed, required this.link, this.linkProblem = false});

  /// Time since recording started; null before the start time is known.
  final Duration? elapsed;

  /// The link to the other phone, e.g. "Secondary OK".
  final String link;

  /// True when [link] is bad news; it is then shown in amber.
  final bool linkProblem;
}

/// Hours and minutes only ("1:07"): the dark screen redraws once a minute,
/// so seconds would always be stale.
String formatDarkElapsed(Duration d) => '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}';

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

  /// What the dark screen shows: elapsed time and the link to the other phone.
  final DarkStatus Function() status;
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

  final DarkStatus status;
  final VoidCallback onWake;

  // Light enough to read at 1% backlight; lit text costs little on OLED at
  // that brightness, the saving comes from the backlight and paused preview.
  static const _label = Color(0xFF8A8A8A);
  static const _time = Color(0xFFB8B8B8);
  static const _hint = Color(0xFF6A6A6A);
  static const _problem = Color(0xFFE0A030);

  @override
  Widget build(BuildContext context) {
    // Drift the text around a 3x3 grid, one step a minute, so no pixels
    // stay lit for the whole game.
    final step = DateTime.now().minute % 9;
    final align = Alignment(-0.8 + 0.8 * (step % 3), -0.8 + 0.8 * (step ~/ 3));
    final elapsed = status.elapsed;
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
              const Text('REC',
                  style: TextStyle(color: _label, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 3)),
              if (elapsed != null)
                Text(
                  formatDarkElapsed(elapsed),
                  style: const TextStyle(
                    color: _time,
                    fontSize: 56,
                    fontWeight: FontWeight.w300,
                    height: 1.1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              const SizedBox(height: 4),
              Text(status.link,
                  style: TextStyle(color: status.linkProblem ? _problem : _label, fontSize: 16)),
              const SizedBox(height: 12),
              const Text('Tap to show the screen', style: TextStyle(color: _hint, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
