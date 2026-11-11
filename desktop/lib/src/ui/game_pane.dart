// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:osb_core/osb_core.dart';

import '../brand.dart';
import '../game_controller.dart';
import '../services.dart';
import 'ball_views.dart';
import 'cameras_check.dart';
import 'games_screen.dart';
import 'kits_check.dart';
import 'pitch_check.dart';
import 'share_views.dart';

String formatGb(int bytes) => '${(bytes / gb).toStringAsFixed(bytes < 10 * gb ? 1 : 0)} GB';

String formatDuration(double seconds) {
  final m = (seconds / 60).round();
  if (m < 1) return 'under a minute';
  if (m < 60) return '$m min';
  final h = m ~/ 60;
  return '$h h ${(m % 60).toString().padLeft(2, '0')} min';
}

class GamePane extends StatelessWidget {
  const GamePane({super.key, required this.controller, this.otherBusy});
  final GameController controller;

  /// Another game is using the engine (one at a time).
  final GameSummary? otherBusy;

  @override
  Widget build(BuildContext context) {
    final ctl = controller;
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final q = ctl.questions;
    final question = ctl.phase != Phase.questions || q == null
        ? null
        : (q.cameras?.pending ?? false)
        ? CamerasCheck(controller: ctl, question: q.cameras!)
        : (q.pitch?.pending ?? false)
        ? PitchCheck(controller: ctl, question: q.pitch!)
        : (q.kits?.pending ?? false)
        ? KitsCheck(controller: ctl, question: q.kits!)
        : null;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(28, 36, 28, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(formatWhen(ctl.summary.when), style: t.headlineSmall),
                const SizedBox(height: 4),
                Text(_subtitle(ctl), style: t.bodyMedium?.copyWith(color: c.inkMuted)),
              ],
            ),
          ),
          // The game's folder appears when its download starts.
          if (ctl.folder?.existsSync() ?? false)
            TextButton.icon(
              onPressed: () => openFile(ctl.folder!.path),
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('Show in Finder'),
            ),
        ],
      ),
    );
    final banner = ctl.error == null
        ? null
        : Container(
            margin: const EdgeInsets.fromLTRB(28, 0, 28, 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: c.coralTint, borderRadius: BorderRadius.circular(BrandRadius.sm)),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: c.coral),
                const SizedBox(width: 12),
                Expanded(child: Text(ctl.error!, style: t.bodyMedium)),
                if (ctl.errorLog != null)
                  TextButton(onPressed: () => openFile(_logPath(ctl)), child: const Text('Show the log')),
              ],
            ),
          );
    // A question fills the pane; the steps scroll.
    if (question != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          ?banner,
          Expanded(child: question),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        header,
        ?banner,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: _Body(controller: ctl, otherBusy: otherBusy),
        ),
      ],
    );
  }

  String _logPath(GameController ctl) {
    final log = ctl.errorLog!;
    return log.startsWith('/') ? log : '${ctl.folder!.path}/$log';
  }

  static String _subtitle(GameController ctl) {
    final r = ctl.recording;
    if (r == null) return '';
    final phones = r.devices.map((d) => d.model ?? d.role ?? 'phone').join(' + ');
    final bytes = r.expectedBytes;
    return [if (phones.isNotEmpty) phones, if (bytes != null) formatGb(bytes)].join(' · ');
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller, this.otherBusy});
  final GameController controller;
  final GameSummary? otherBusy;

  @override
  Widget build(BuildContext context) {
    final ctl = controller;
    final t = Theme.of(context).textTheme;
    final c = BrandColors.of(context);
    final blocked = ctl.checks.any((x) => x.blocking && !x.ok);
    final engineNote = otherBusy == null
        ? null
        : Text(
            'The game of ${formatWhen(otherBusy!.when)} is using the engine. One game at a time.',
            style: t.bodyMedium?.copyWith(color: c.inkMuted),
          );
    final steps = _Steps(phase: ctl.phase);
    final segments = TextButton(onPressed: () => showSegmentDetails(context, ctl), child: const Text('Segments'));
    switch (ctl.phase) {
      case Phase.loading:
        return const Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        );
      case Phase.needsDownload:
        final bytes = ctl.recording?.expectedBytes;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            steps,
            const SizedBox(height: 24),
            Text('First the footage comes to this Mac.', style: t.titleMedium),
            const SizedBox(height: 8),
            Text(
              'It downloads from your account, then the engine checks every file before using it.',
              style: t.bodyMedium?.copyWith(color: c.inkMuted),
            ),
            const SizedBox(height: 16),
            _Checks(checks: ctl.checks),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: blocked || ctl.recording?.ready != true ? null : ctl.startDownload,
              icon: const Icon(Icons.download),
              label: Text(bytes == null ? 'Download the footage' : 'Download the footage (${formatGb(bytes)})'),
            ),
          ],
        );
      case Phase.downloading:
        final p = ctl.download;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            steps,
            const SizedBox(height: 24),
            _Progress(
              title: 'Downloading the footage',
              fraction: p?.fraction,
              detail: p == null
                  ? 'Starting…'
                  : [
                      '${formatGb(p.doneBytes)} of ${formatGb(p.totalBytes)}',
                      if (p.bytesPerSecond != null) '${(p.bytesPerSecond! * 8 / 1e6).toStringAsFixed(0)} Mbit/s',
                      if (ctl.etaS != null) 'about ${formatDuration(ctl.etaS!)} left',
                    ].join(' · '),
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: ctl.stop, child: const Text('Pause')),
            const SizedBox(height: 8),
            Text('Paused or quit, it carries on where it was.', style: t.bodySmall?.copyWith(color: c.inkMuted)),
          ],
        );
      case Phase.needsPrepare:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            steps,
            const SizedBox(height: 24),
            Text('The footage is here. Next the engine gets the game ready for your checks.', style: t.titleMedium),
            const SizedBox(height: 16),
            ?engineNote,
            const SizedBox(height: 8),
            FilledButton(onPressed: otherBusy != null ? null : ctl.prepare, child: const Text('Get ready')),
          ],
        );
      case Phase.preparing:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            steps,
            const SizedBox(height: 24),
            _Progress(
              title: ctl.activity ?? 'Getting ready',
              fraction: null,
              detail: 'Syncing the phones, mapping the pitch and grouping the kits takes a quarter of an hour or so.',
            ),
            const SizedBox(height: 6),
            StepClock(startedAt: ctl.stepStartedAt, usualS: usualStepSeconds[ctl.step]),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(onPressed: ctl.stop, child: const Text('Stop')),
                if (ctl.stepLog != null)
                  TextButton(onPressed: () => openFile(ctl.stepLog!), child: const Text('Show the log')),
              ],
            ),
          ],
        );
      case Phase.questions:
        // Answered, and the engine has nothing pending yet (a reload clears this).
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            steps,
            const SizedBox(height: 24),
            FilledButton(onPressed: otherBusy != null ? null : ctl.prepare, child: const Text('Carry on')),
          ],
        );
      case Phase.readyToRun:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            steps,
            const SizedBox(height: 24),
            Text('Checked. Now the game is processed: overnight.', style: t.titleMedium),
            const SizedBox(height: 8),
            Text(
              'The engine finds the ball and the players in every frame and follows the play. It takes hours; the Mac '
              'stays awake while it works, and pauses if it goes on battery. You can quit the app: it carries on where '
              'it was next time.',
              style: t.bodyMedium?.copyWith(color: c.inkMuted),
            ),
            const SizedBox(height: 16),
            _Checks(checks: ctl.checks),
            const SizedBox(height: 16),
            ?engineNote,
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: otherBusy != null || blocked ? null : ctl.run,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Process the game'),
            ),
            // A game stopped part-way has segments to show, and may already know about its ball.
            if (ctl.chunkDetails.isNotEmpty) ...[const SizedBox(height: 8), segments],
            BallNotice(controller: ctl),
            ShareCard(controller: ctl),
          ],
        );
      case Phase.running:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            steps,
            const SizedBox(height: 24),
            _Progress(
              title: ctl.activity ?? 'Processing the game',
              fraction: ctl.shownFraction,
              detail: runDetail(ctl),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(onPressed: ctl.stop, child: const Text('Pause')),
                segments,
                if (ctl.stepLog != null)
                  TextButton(onPressed: () => openFile(ctl.stepLog!), child: const Text('Show the log')),
              ],
            ),
            const SizedBox(height: 8),
            Text('Paused or quit, it carries on where it was.', style: t.bodySmall?.copyWith(color: c.inkMuted)),
            BallNotice(controller: ctl),
            ShareCard(controller: ctl),
          ],
        );
      case Phase.paused:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            steps,
            const SizedBox(height: 24),
            Text('Paused: the Mac is on battery.', style: t.titleMedium),
            const SizedBox(height: 8),
            Text('Plug it in and processing carries on by itself.', style: t.bodyMedium?.copyWith(color: c.inkMuted)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(onPressed: ctl.stop, child: const Text('Don’t carry on by itself')),
                segments,
              ],
            ),
            BallNotice(controller: ctl),
            ShareCard(controller: ctl),
          ],
        );
      case Phase.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            steps,
            const SizedBox(height: 24),
            Text('The game video is ready.', style: t.titleMedium),
            const SizedBox(height: 8),
            if (ctl.output != null)
              SelectableText(ctl.output!, style: t.bodySmall?.copyWith(fontFamily: BrandFonts.mono)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: ctl.output == null ? null : () => openFile(ctl.output!),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Watch'),
                ),
                OutlinedButton.icon(
                  onPressed: ctl.output == null ? null : () => revealInFinder(ctl.output!),
                  icon: const Icon(Icons.folder_outlined),
                  label: const Text('Show in Finder'),
                ),
                if (ctl.chunkDetails.isNotEmpty) segments,
              ],
            ),
            BallNotice(controller: ctl),
            ShareCard(controller: ctl),
            if (!ctl.ballLow && ctl.chunkDetails.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Help the engine follow the ball better', style: t.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Mark the ball in 50 pictures from this game. It goes into the next version of the engine.',
                style: t.bodyMedium?.copyWith(color: c.inkMuted),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => showBallLabelling(context, ctl), child: const Text('Mark the ball')),
            ],
          ],
        );
    }
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.phase});
  final Phase phase;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final at = switch (phase) {
      Phase.loading || Phase.needsDownload || Phase.downloading => 0,
      Phase.needsPrepare || Phase.preparing => 1,
      Phase.questions => 2,
      Phase.readyToRun || Phase.running || Phase.paused => 3,
      Phase.done => 4,
    };
    const names = ['Download', 'Get ready', 'Check', 'Process', 'Watch'];
    return Row(
      children: [
        for (var i = 0; i < names.length; i++) ...[
          if (i > 0) Expanded(child: Divider(color: i <= at ? c.grass : c.border, thickness: 2)),
          CircleAvatar(
            radius: 13,
            backgroundColor: i < at ? c.grass : (i == at ? c.grassTint : c.surfaceSunken),
            child: i < at
                ? Icon(Icons.check, size: 15, color: c.onGrass)
                : Text('${i + 1}', style: t.labelMedium?.copyWith(color: i == at ? c.grassStrong : c.inkMuted)),
          ),
          const SizedBox(width: 6),
          Text(names[i], style: t.labelLarge?.copyWith(color: i <= at ? c.ink : c.inkMuted)),
        ],
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.title, required this.fraction, required this.detail});
  final String title;
  final double? fraction;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = BrandColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: t.titleMedium),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: fraction, minHeight: 8),
        ),
        const SizedBox(height: 8),
        Text(detail, style: t.bodyMedium?.copyWith(color: c.inkMuted)),
      ],
    );
  }
}

class _Checks extends StatelessWidget {
  const _Checks({required this.checks});
  final List<Check> checks;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final x in checks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  x.ok ? Icons.check_circle : (x.blocking ? Icons.cancel : Icons.warning_amber),
                  size: 18,
                  color: x.ok ? c.grass : (x.blocking ? c.coral : c.sunText),
                ),
                const SizedBox(width: 8),
                Text('${x.title}: ', style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                Expanded(child: Text(x.detail, style: t.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}

/// How long the current step has been running, beside how long it usually
/// takes, ticking: so a long step reads as working, not stuck.
class StepClock extends StatefulWidget {
  const StepClock({super.key, required this.startedAt, this.usualS});
  final DateTime? startedAt;
  final int? usualS;

  @override
  State<StepClock> createState() => _StepClockState();
}

class _StepClockState extends State<StepClock> {
  late final Timer _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final started = widget.startedAt;
    if (started == null) return const SizedBox.shrink();
    final s = DateTime.now().difference(started).inSeconds;
    final so = s < 60 ? '$s s so far' : '${s ~/ 60} min ${(s % 60).toString().padLeft(2, '0')} s so far';
    final usual = widget.usualS;
    final text = [
      so,
      if (usual != null) 'usually about ${usual < 90 ? '1 min' : '${(usual / 60).round()} min'}',
      if (usual != null && s > usual * 2) 'slower than usual, still working',
    ].join(' · ');
    return Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: BrandColors.of(context).inkMuted));
  }
}

/// The line under the processing bar. Before the engine has finished its
/// first chunk it can't say how long the rest takes, so the app estimates
/// from the chunk count and says so.
String runDetail(GameController ctl) {
  final so = ctl.runElapsedS == null ? null : '${formatDuration(ctl.runElapsedS!)} so far';
  final eta = ctl.shownEtaS;
  if (eta == null) return so ?? 'Starting…';
  if (ctl.etaIsEstimate) {
    return [
      ?so,
      'about ${formatDuration(eta)} left',
      'an estimate until the first 10 minutes of video are done',
    ].join(' · ');
  }
  return [
    if ((ctl.fraction ?? 0) > 0) '${(ctl.fraction! * 100).toStringAsFixed(0)}%',
    ?so,
    'about ${formatDuration(eta)} left',
  ].join(' · ');
}
