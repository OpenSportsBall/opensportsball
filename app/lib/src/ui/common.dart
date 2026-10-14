// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/material.dart';

/// Pairing QR payload: `opensportsball://pair?v=1&game=<uuid>`.
String pairingUri(String gameId) => 'opensportsball://pair?v=1&game=$gameId';

final _uuidPattern =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// Returns the game id from a scanned pairing code, or null if it isn't one.
String? parsePairingUri(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'opensportsball' || uri.host != 'pair') return null;
  if (uri.queryParameters['v'] != '1') return null;
  final game = uri.queryParameters['game']?.toLowerCase();
  return game != null && _uuidPattern.hasMatch(game) ? game : null;
}

String formatBytes(int bytes) {
  const gb = 1024 * 1024 * 1024, mb = 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).toStringAsFixed(0)} MB';
}

String formatElapsed(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

/// Rebuilds its child every second, for running clocks.
class Ticker extends StatefulWidget {
  const Ticker({super.key, required this.builder});
  final WidgetBuilder builder;
  @override
  State<Ticker> createState() => _TickerState();
}

class _TickerState extends State<Ticker> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// A label / value row in a status panel.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.warn = false});
  final String label;
  final String value;
  final bool warn;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      // The label keeps its width; a long value wraps instead of squeezing
      // the label into one letter per line.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: warn ? theme.colorScheme.error : null,
                fontWeight: warn ? FontWeight.bold : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PanelSection extends StatelessWidget {
  const PanelSection({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

class ErrorText extends StatelessWidget {
  const ErrorText(this.message, {super.key});
  final String? message;
  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }
}

Future<bool> confirm(BuildContext context, String title, String body, String action) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
      ],
    ),
  );
  return ok ?? false;
}

/// Preview area plus a fixed-width side panel, for landscape screens.
class PreviewLayout extends StatelessWidget {
  const PreviewLayout({super.key, required this.preview, required this.panel, this.footer});
  final Widget preview;
  final List<Widget> panel;

  /// Pinned below the scrolling panel, e.g. the record button, so it is
  /// always on screen.
  final Widget? footer;
  @override
  Widget build(BuildContext context) {
    // Each side keeps clear of the display cutout on its own edge: the black
    // preview box runs under the camera hole so the inset doesn't show as a
    // stripe, and the panel grows by its inset so it keeps its full width.
    return Row(
      children: [
        Expanded(
          child: ColoredBox(
            color: Colors.black,
            child: SafeArea(right: false, child: Center(child: preview)),
          ),
        ),
        SizedBox(
          width: 300 + MediaQuery.paddingOf(context).right,
          child: SafeArea(
            left: false,
            child: Column(
              children: [
                Expanded(child: ListView(padding: const EdgeInsets.all(16), children: panel)),
                if (footer != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), child: footer),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class RecordButton extends StatelessWidget {
  const RecordButton({
    super.key,
    required this.recording,
    required this.busy,
    required this.onPressed,
    this.startLabel = 'Start recording',
    this.stopLabel = 'Stop recording',
  });
  final bool recording;
  final bool busy;
  final VoidCallback? onPressed;
  final String startLabel;
  final String stopLabel;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: recording ? scheme.error : null,
        minimumSize: const Size.fromHeight(56),
      ),
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(recording ? Icons.stop : Icons.fiber_manual_record),
      label: Text(recording ? stopLabel : startLabel),
    );
  }
}
