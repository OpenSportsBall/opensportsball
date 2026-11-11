// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// What the app shows about the ball and the game's chunks while and after
/// the engine processes it: the notice when the models don't know this
/// ball, each segment's details, and the ball labelling screen
/// (docs/MAC-APP-PLAN.md, "Ball labels and must-see moments").
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:osb_core/osb_core.dart';

import '../brand.dart';
import '../game_controller.dart';
import '../services.dart';

String _clock(double seconds) {
  final s = seconds.round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}'
      : '$m:${(s % 60).toString().padLeft(2, '0')}';
}

String _took(double seconds) {
  final m = (seconds / 60).round();
  if (m < 1) return '${seconds.round()} s';
  return m < 60 ? '$m min' : '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
}

/// Shown from the game's second segment on when the camera is hardly
/// finding the ball: said early, not after a night's processing.
class BallNotice extends StatelessWidget {
  const BallNotice({super.key, required this.controller});
  final GameController controller;

  @override
  Widget build(BuildContext context) {
    final ctl = controller;
    final b = ctl.ball;
    if (b == null || !ctl.ballLow) return const SizedBox.shrink();
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final done = ctl.phase == Phase.done;
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.sunTint, borderRadius: BorderRadius.circular(BrandRadius.sm)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sports_soccer, color: c.sunText),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('The engine doesn’t know this ball yet', style: t.titleSmall),
                const SizedBox(height: 6),
                Text(
                  'The camera found the ball in ${(b.aimShare * 100).round()}% of the '
                  '${b.byChunk.length == 1 ? 'segment' : '${b.byChunk.length} segments'} done so far '
                  '(${b.byChunk.map((p) => '$p%').join(', ')}). ${done ? 'This video follows' : 'This video will follow'} '
                  'the players more than the ball. Processing ${done ? 'finished' : 'carries on'} as usual.',
                  style: t.bodyMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'You can teach it: mark the ball in 50 pictures from this game. That doesn’t change this video; it '
                  'goes into the next version of the engine, for every game with a ball like this one.',
                  style: t.bodyMedium?.copyWith(color: c.inkMuted),
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => showBallLabelling(context, ctl), child: const Text('Mark the ball')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showSegmentDetails(BuildContext context, GameController controller) => showDialog<void>(
  context: context,
  builder: (_) => SegmentDetailsDialog(controller: controller),
);

/// Each ten-minute segment of the game: where its two stages stand, how
/// long they took, what the camera made of the ball, and the logs.
class SegmentDetailsDialog extends StatefulWidget {
  const SegmentDetailsDialog({super.key, required this.controller});
  final GameController controller;

  @override
  State<SegmentDetailsDialog> createState() => _SegmentDetailsState();
}

class _SegmentDetailsState extends State<SegmentDetailsDialog> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.loadChunkDetails());
    // A stage ends every half hour or so; the running one's clock ticks.
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => widget.controller.loadChunkDetails());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = BrandColors.of(context);
    return AlertDialog(
      title: const Text('Segments'),
      content: SizedBox(
        width: 760,
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final chunks = widget.controller.chunkDetails;
            if (chunks.isEmpty) {
              return Text(
                'Nothing yet: segments appear once processing has started.',
                style: t.bodyMedium?.copyWith(color: c.inkMuted),
              );
            }
            final live = widget.controller.phase == Phase.running;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The game is processed in segments of ten minutes. Each goes through two stages: finding the ball '
                  'and the players, then moving the camera and making the video.',
                  style: t.bodyMedium?.copyWith(color: c.inkMuted),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Table(
                      columnWidths: const {
                        0: FixedColumnWidth(44),
                        1: FixedColumnWidth(120),
                        2: FlexColumnWidth(),
                        3: FlexColumnWidth(),
                        4: FixedColumnWidth(150),
                      },
                      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                      children: [
                        TableRow(
                          children: [
                            for (final h in const ['#', 'Game time', 'Ball and players', 'Camera and video', 'Ball'])
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Text(h, style: t.labelMedium?.copyWith(color: c.inkMuted)),
                              ),
                          ],
                        ),
                        for (final ch in chunks)
                          TableRow(
                            decoration: BoxDecoration(
                              border: Border(top: BorderSide(color: c.border)),
                            ),
                            children: [
                              Text('${ch.chunk + 1}', style: t.bodyMedium),
                              Text('${_clock(ch.startS)} – ${_clock(ch.startS + ch.seconds)}', style: t.bodyMedium),
                              _StageCell(stage: ch.ball, live: live),
                              _StageCell(stage: ch.follow, live: live),
                              _BallCell(chunk: ch),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        if (widget.controller.folder != null)
          TextButton(
            onPressed: () => openFile('${widget.controller.folder!.path}/fullgame/logs'),
            child: const Text('Show all logs'),
          ),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ],
    );
  }
}

class _StageCell extends StatelessWidget {
  const _StageCell({required this.stage, required this.live});
  final ChunkStage stage;

  /// The engine is processing now (else a "running" stage was stopped there).
  final bool live;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final running = stage.status == 'running';
    final (icon, color, text) = switch (stage.status) {
      'done' => (Icons.check_circle, c.grass, stage.seconds == null ? 'Done' : 'Done in ${_took(stage.seconds!)}'),
      'failed' => (Icons.cancel, c.coral, 'Failed'),
      'running' when live => (
        Icons.autorenew,
        c.sky,
        stage.startedAt == null
            ? 'Working'
            : 'Working, ${_took(DateTime.now().difference(stage.startedAt!).inSeconds.toDouble())} so far',
      ),
      'running' => (Icons.pause_circle_outline, c.inkMuted, 'Stopped part-way'),
      _ => (Icons.schedule, c.inkMuted, 'Waiting'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: t.bodyMedium?.copyWith(color: running || stage.status == 'done' ? c.ink : color)),
          ),
          if (stage.log != null)
            IconButton(
              tooltip: 'Show the log',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: () => openFile(stage.log!),
              icon: const Icon(Icons.article_outlined),
            ),
        ],
      ),
    );
  }
}

class _BallCell extends StatelessWidget {
  const _BallCell({required this.chunk});
  final ChunkDetail chunk;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final aim = chunk.ballAimPct;
    if (aim == null) return Text('—', style: t.bodyMedium?.copyWith(color: c.inkMuted));
    final low = aim < 10;
    return Tooltip(
      message: [
        'The camera aimed at the ball in $aim% of this segment.',
        if (chunk.ballDetectedPct != null) 'The ball was seen in ${chunk.ballDetectedPct}% of its frames.',
      ].join('\n'),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: aim / 100,
                minHeight: 6,
                color: low ? c.sun : c.grass,
                backgroundColor: c.border,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('$aim%', style: t.bodyMedium?.copyWith(color: low ? c.sunText : c.ink)),
        ],
      ),
    );
  }
}

Future<void> showBallLabelling(BuildContext context, GameController controller) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => Dialog.fullscreen(child: BallLabelScreen(controller: controller)),
);

/// Marking the ball in a set of pictures from the game: tap it, pick one of
/// the engine's suggestions, or say it isn't there. Locked until the user
/// agrees to share the pictures and labels, which is what they are for.
class BallLabelScreen extends StatefulWidget {
  const BallLabelScreen({super.key, required this.controller});
  final GameController controller;

  @override
  State<BallLabelScreen> createState() => _BallLabelState();
}

class _BallLabelState extends State<BallLabelScreen> {
  /// A tap this close to a suggestion (image pixels) takes the suggestion.
  static const _snapPx = 24.0;
  static const _saveEvery = 10;

  BallLabelSet? _set;
  String? _error;
  bool _working = false;
  bool _finished = false;
  int _at = 0;
  final Map<String, BallLabel> _labels = {};
  final Map<String, BallLabel> _unsaved = {};
  final _view = TransformationController();
  Size _viewport = Size.zero;

  Settings get _settings => widget.controller.settings;

  @override
  void initState() {
    super.initState();
    if (_settings.shareLabels) unawaited(_load());
  }

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final s = await widget.controller.ballSet();
      if (!mounted) return;
      setState(() {
        _set = s;
        _labels
          ..clear()
          ..addAll(s.labels);
        final first = s.frames.indexWhere((f) => !_labels.containsKey(f.id));
        _at = first < 0 ? 0 : first;
      });
      _zoomToSuggestion();
    } on OsbException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<bool> _save() async {
    final s = _set;
    if (s == null || _unsaved.isEmpty) return true;
    final sending = Map.of(_unsaved);
    try {
      final now = await widget.controller.saveBallLabels(s, sending);
      for (final k in sending.keys) {
        if (identical(_unsaved[k], sending[k])) _unsaved.remove(k);
      }
      if (mounted) setState(() => _set = now);
      return true;
    } on OsbException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return false;
    }
  }

  void _label(BallLabel l) {
    final f = _set!.frames[_at];
    setState(() {
      _labels[f.id] = l;
      _unsaved[f.id] = l;
    });
    if (_unsaved.length >= _saveEvery) unawaited(_save());
  }

  void _go(int to) {
    final n = _set!.frames.length;
    if (to < 0 || to >= n) return;
    setState(() => _at = to);
    _zoomToSuggestion();
  }

  Future<void> _finish() async {
    setState(() => _working = true);
    final ok = await _save();
    if (mounted) {
      setState(() {
        _working = false;
        _finished = ok;
      });
    }
  }

  Future<void> _close() async {
    final nav = Navigator.of(context);
    setState(() => _working = true);
    await _save();
    nav.pop();
  }

  /// The frame fitted into the viewport (before any zoom).
  ({double scale, Offset origin}) _fit(BallFrame f) {
    final s = math.min(_viewport.width / f.width, _viewport.height / f.height);
    return (scale: s, origin: Offset((_viewport.width - f.width * s) / 2, (_viewport.height - f.height * s) / 2));
  }

  void _zoomOut() => _view.value = Matrix4.identity();

  /// A ball is a few pixels of a 4K frame: start zoomed in on the best guess.
  void _zoomToSuggestion() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = _set;
      if (!mounted || s == null || _viewport == Size.zero) return;
      final f = s.frames[_at];
      final label = _labels[f.id];
      final Offset? target = label is BallAt
          ? Offset(label.x, label.y)
          : (f.suggestions.isEmpty ? null : Offset(f.suggestions.first.x, f.suggestions.first.y));
      if (target == null) {
        _zoomOut();
        return;
      }
      const zoom = 5.0;
      final fit = _fit(f);
      final p = fit.origin + target * fit.scale;
      _view.value = Matrix4.identity()
        ..translateByDouble(_viewport.width / 2 - p.dx * zoom, _viewport.height / 2 - p.dy * zoom, 0, 1)
        ..scaleByDouble(zoom, zoom, 1, 1);
    });
  }

  void _tap(Offset inFrameBox, BallFrame f, double scale) {
    var x = inFrameBox.dx / scale, y = inFrameBox.dy / scale;
    for (final s in f.suggestions) {
      if ((Offset(s.x, s.y) - Offset(x, y)).distance <= _snapPx) {
        x = s.x;
        y = s.y;
        break;
      }
    }
    _label(BallAt(x.clamp(0, f.width.toDouble()), y.clamp(0, f.height.toDouble())));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = BrandColors.of(context);
    final s = _set;
    Widget body;
    if (!_settings.shareLabels) {
      body = _Agreement(
        onAgree: () async {
          await _settings.set('shareLabels', true);
          if (mounted) unawaited(_load());
        },
      );
    } else if (_finished) {
      body = _Centered(
        children: [
          Icon(Icons.check_circle, size: 44, color: c.grass),
          const SizedBox(height: 12),
          Text('Thank you: ${s?.labelled ?? 0} pictures marked.', style: t.titleLarge),
          const SizedBox(height: 8),
          Text(
            'They are saved with this game, ready to share. They teach the next version of the engine this ball.',
            style: t.bodyMedium?.copyWith(color: c.inkMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
        ],
      );
    } else if (s == null) {
      body = _Centered(
        children: _error != null
            ? [
                Icon(Icons.error_outline, size: 40, color: c.coral),
                const SizedBox(height: 12),
                Text(_error!, style: t.bodyLarge, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: _load, child: const Text('Try again')),
              ]
            : [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('Picking pictures from the game', style: t.titleMedium),
                const SizedBox(height: 6),
                Text('This takes a minute or two.', style: t.bodyMedium?.copyWith(color: c.inkMuted)),
              ],
      );
    } else if (s.frames.isEmpty) {
      body = _Centered(children: [Text('The engine found no pictures to mark in this game.', style: t.bodyLarge)]);
    } else {
      body = _frames(context, s);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
          child: Row(
            children: [
              Expanded(child: Text('Mark the ball', style: t.headlineSmall)),
              if (_working && s != null)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              TextButton.icon(
                onPressed: _working && s != null
                    ? null
                    : (s == null || _finished ? () => Navigator.of(context).pop() : _close),
                icon: const Icon(Icons.close, size: 18),
                label: Text(s == null || _finished || _unsaved.isEmpty ? 'Close' : 'Save and close'),
              ),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  Widget _frames(BuildContext context, BallLabelSet s) {
    final t = Theme.of(context).textTheme;
    final c = BrandColors.of(context);
    final f = s.frames[_at];
    final label = _labels[f.id];
    final n = s.frames.length;
    final marked = s.frames.where((x) => _labels.containsKey(x.id)).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Click the match ball. A ring is where the engine thinks it may be: click it if it’s right. '
                'Scroll or pinch to zoom, drag to move.',
                style: t.bodyMedium?.copyWith(color: c.inkMuted),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Picture ${_at + 1} of $n', style: t.titleSmall),
                  const SizedBox(width: 12),
                  Text('${_clock(f.videoT)} into the game', style: t.bodyMedium?.copyWith(color: c.inkMuted)),
                  const Spacer(),
                  Text('$marked of $n marked', style: t.bodyMedium?.copyWith(color: c.inkMuted)),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: marked / n, minHeight: 6),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text('Couldn’t save: $_error', style: t.bodyMedium?.copyWith(color: c.coral)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ColoredBox(
            color: Colors.black,
            child: LayoutBuilder(
              builder: (context, box) {
                final first = _viewport == Size.zero;
                _viewport = box.biggest;
                if (first) _zoomToSuggestion();
                final fit = _fit(f);
                return InteractiveViewer(
                  transformationController: _view,
                  minScale: 1,
                  maxScale: 16,
                  child: SizedBox(
                    width: box.maxWidth,
                    height: box.maxHeight,
                    child: Stack(
                      children: [
                        Positioned(
                          left: fit.origin.dx,
                          top: fit.origin.dy,
                          width: f.width * fit.scale,
                          height: f.height * fit.scale,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (d) => _tap(d.localPosition, f, fit.scale),
                            child: ListenableBuilder(
                              listenable: _view,
                              builder: (context, child) => CustomPaint(
                                foregroundPainter: _Marks(
                                  frame: f,
                                  label: label,
                                  scale: fit.scale,
                                  zoom: _view.value.getMaxScaleOnAxis(),
                                  suggestion: c.sun,
                                  chosen: c.grass,
                                ),
                                child: child,
                              ),
                              child: Image.file(
                                File(f.image),
                                key: ValueKey(f.id),
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.medium,
                                errorBuilder: (_, _, _) => const Center(
                                  child: Text('This picture is missing.', style: TextStyle(color: Colors.white70)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Row(
            children: [
              // Wraps onto a second line in a narrow window.
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton(onPressed: _at == 0 ? null : () => _go(_at - 1), child: const Text('Back')),
                    ChoiceChip(
                      label: const Text('The ball isn’t in the picture'),
                      selected: label is NoBall,
                      onSelected: (_) => _label(const NoBall()),
                    ),
                    ChoiceChip(
                      label: const Text('Can’t tell'),
                      selected: label is BallUnsure,
                      onSelected: (_) => _label(const BallUnsure()),
                    ),
                    TextButton(onPressed: _zoomOut, child: const Text('Whole picture')),
                    if (f.suggestions.isNotEmpty || label is BallAt)
                      TextButton(
                        onPressed: _zoomToSuggestion,
                        child: Text(label is BallAt ? 'Zoom to the ball' : 'Zoom to the ring'),
                      ),
                    if (label is BallAt) Text('Ball marked', style: t.bodyMedium?.copyWith(color: c.grassStrong)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (_at < n - 1)
                FilledButton(onPressed: label == null ? null : () => _go(_at + 1), child: const Text('Next'))
              else
                FilledButton(onPressed: label == null || _working ? null : _finish, child: const Text('Finish')),
            ],
          ),
        ),
      ],
    );
  }
}

/// The engine's suggestions (rings) and the user's mark, drawn the same
/// size on screen at any zoom.
class _Marks extends CustomPainter {
  const _Marks({
    required this.frame,
    required this.label,
    required this.scale,
    required this.zoom,
    required this.suggestion,
    required this.chosen,
  });
  final BallFrame frame;
  final BallLabel? label;
  final double scale, zoom;
  final Color suggestion, chosen;

  @override
  void paint(Canvas canvas, Size size) {
    final r = 14 / zoom, w = 2 / zoom;
    final l = label;
    for (final s in frame.suggestions) {
      if (l is BallAt && l.x == s.x && l.y == s.y) continue;
      canvas.drawCircle(
        Offset(s.x, s.y) * scale,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..color = suggestion,
      );
    }
    if (l is BallAt) {
      final p = Offset(l.x, l.y) * scale;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 1.5
        ..color = chosen;
      canvas.drawCircle(p, r, paint);
      for (final d in const [Offset(1, 0), Offset(-1, 0), Offset(0, 1), Offset(0, -1)]) {
        canvas.drawLine(p + d * r, p + d * (r * 1.8), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Marks old) => old.frame != frame || old.label != label || old.scale != scale || old.zoom != zoom;
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );
}

class _Agreement extends StatelessWidget {
  const _Agreement({required this.onAgree});
  final VoidCallback onAgree;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = BrandColors.of(context);
    return _Centered(
      children: [
        Icon(Icons.lock_outline, size: 40, color: c.inkMuted),
        const SizedBox(height: 12),
        Text('Marking the ball is for sharing', style: t.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 10),
        Text(
          'These marks exist to teach the engine, so they are only useful shared with the OpenSportsBall project. '
          'What is shared: the pictures you mark, which are frames of your game and show the players, often '
          'children; where you marked the ball; and the camera details needed to use them.',
          style: t.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'This version saves them with the game on this Mac, ready to share; nothing is sent yet. You can change '
          'your mind in Settings.',
          style: t.bodyMedium?.copyWith(color: c.inkMuted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          children: [
            OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Not now')),
            FilledButton(onPressed: onAgree, child: const Text('I agree to share them')),
          ],
        ),
      ],
    );
  }
}
