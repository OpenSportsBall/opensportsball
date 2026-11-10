// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// The pitch check (docs/MAC-APP-PLAN.md, "Pitch check"): the empty-pitch
/// panorama with our fitted lines drawn on it. Approve them, or mark the
/// pitch: pick each named point and click where it really is (or skip one
/// you can't see); the engine refits and shows the result again.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:osb_core/osb_core.dart';

import '../brand.dart';
import '../game_controller.dart';

class PitchCheck extends StatefulWidget {
  const PitchCheck({super.key, required this.controller, required this.question});
  final GameController controller;
  final PitchQuestion question;

  @override
  State<PitchCheck> createState() => _PitchCheckState();
}

class _PitchCheckState extends State<PitchCheck> {
  late bool _marking = !widget.question.approveAllowed;
  late final Map<String, PitchPoint> _points = {for (final n in widget.question.points.keys) n: const FromFitPoint()};
  late String? _selected = widget.question.points.keys.firstOrNull;
  bool _share = true;
  final _viewer = TransformationController();
  bool _fitted = false;
  Size _view = Size.zero;

  /// The whole panorama, fitted to the width.
  void _fitAll() {
    final pano = q.panorama;
    if (pano == null || _view.width == 0) return;
    final s = _view.width / pano.width;
    _viewer.value = Matrix4.identity()..scaleByDouble(s, s, 1, 1);
  }

  /// Zooms to [name], where its marking can be clicked precisely.
  void _focus(String? name) {
    final pano = q.panorama;
    if (pano == null || name == null || _view.width == 0) return;
    final at = pano.toPx(_where(name));
    const s = 0.8; // panorama pixels to screen pixels
    _viewer.value = Matrix4.identity()
      ..translateByDouble(_view.width / 2 - at.x * s, _view.height / 2 - at.y * s, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  void _select(String name) {
    setState(() => _selected = name);
    _focus(name);
  }

  @override
  void dispose() {
    _viewer.dispose();
    super.dispose();
  }

  PitchQuestion get q => widget.question;

  Deg _where(String name) {
    final p = _points[name];
    return p is MovedPoint ? p.at : q.points[name]!;
  }

  void _place(Offset local) {
    final pano = q.panorama;
    final name = _selected;
    if (!_marking || pano == null || name == null) return;
    setState(() {
      _points[name] = MovedPoint(pano.toDeg(local.dx, local.dy));
      // On to the next point still where the fit put it.
      final names = q.points.keys.toList();
      final i = names.indexOf(name);
      _selected = [...names.skip(i + 1), ...names.take(i)].where((n) => _points[n] is FromFitPoint).firstOrNull ?? name;
    });
    _focus(_selected);
  }

  int get _moved => _points.values.whereType<MovedPoint>().length;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final ctl = widget.controller;
    final pano = q.panorama;
    final folder = ctl.folder!.path;
    final image = Stack(
      children: [
        Positioned.fill(child: Image.file(File('$folder/${q.background}'), fit: BoxFit.fill)),
        Positioned.fill(
          child: CustomPaint(
            painter: _PitchPainter(
              viewer: _viewer,
              question: q,
              where: _where,
              showPoints: _marking,
              selected: _selected,
              skipped: {
                for (final e in _points.entries)
                  if (e.value is SkippedPoint) e.key,
              },
              moved: {
                for (final e in _points.entries)
                  if (e.value is MovedPoint) e.key,
              },
              lineColor: c.sun,
              pointColor: c.sky,
              selectedColor: c.coral,
            ),
          ),
        ),
      ],
    );
    final viewer = pano == null
        ? Image.file(File('$folder/${q.overlay ?? q.background}'))
        : ClipRect(
            child: InteractiveViewer(
              transformationController: _viewer,
              minScale: 0.05,
              maxScale: 4,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(200),
              child: LayoutBuilder(
                builder: (context, _) {
                  return GestureDetector(
                    onTapUp: (d) => _place(d.localPosition),
                    child: SizedBox(width: pano.width, height: pano.height, child: image),
                  );
                },
              ),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_marking ? 'Mark the pitch' : 'Do the lines sit on the pitch?', style: t.titleLarge),
              const SizedBox(height: 4),
              Text(
                _marking
                    ? 'Pick a point on the right, then click where it really is on the picture. Skip any you can’t see. '
                          'Scroll or pinch to zoom.'
                    : 'This is the pitch with the players taken out. Yellow is where we think the lines and goals are. '
                          'Everything after this depends on it, so check the corners, the boxes and the halfway line.',
                style: t.bodyMedium?.copyWith(color: c.inkMuted),
              ),
              if (q.problem != null) ...[
                const SizedBox(height: 8),
                Text(q.problem!, style: t.bodyMedium?.copyWith(color: c.coral)),
              ],
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, outer) {
                    // As tall as the panorama at this width, plus room for lines
                    // the cameras don't see (the near touchline), no taller.
                    final h = pano == null || _marking
                        ? outer.maxHeight
                        : math.min(outer.maxHeight, (outer.maxWidth - 28) * pano.height / pano.width * 1.35);
                    return Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        height: h,
                        child: Container(
                          margin: const EdgeInsets.only(left: 28),
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(BrandRadius.sm),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: pano == null
                              ? viewer
                              : LayoutBuilder(
                                  builder: (context, box) {
                                    // Start with the whole panorama fitted to the width.
                                    _view = box.biggest;
                                    if (!_fitted) {
                                      _fitted = true;
                                      WidgetsBinding.instance.addPostFrameCallback(
                                        (_) => _marking ? _focus(_selected) : _fitAll(),
                                      );
                                    }
                                    return viewer;
                                  },
                                ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_marking)
                SizedBox(
                  width: 290,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 20, 0),
                    children: [
                      for (final name in q.points.keys)
                        _PointRow(
                          name: name,
                          state: _points[name]!,
                          selected: name == _selected,
                          onTap: () => _select(name),
                          onSkip: () => setState(
                            () => _points[name] = _points[name] is SkippedPoint
                                ? const FromFitPoint()
                                : const SkippedPoint(),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 14, 28, 20),
          child: Row(
            children: [
              Switch(value: _share, onChanged: (v) => setState(() => _share = v)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Share this pitch map to help improve pitch detection',
                  style: t.bodyMedium?.copyWith(color: c.inkMuted),
                ),
              ),
              if (!_marking) ...[
                OutlinedButton(
                  onPressed: () {
                    setState(() => _marking = true);
                    // The mark list takes room: zoom once the view has its new size.
                    WidgetsBinding.instance.addPostFrameCallback((_) => _focus(_selected));
                  },
                  child: const Text('No, mark the pitch'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: !q.approveAllowed || ctl.busy
                      ? null
                      : () => ctl.answer((a) => a.approvePitch(q.round, share: _share)),
                  child: const Text('Yes, they sit on the lines'),
                ),
              ] else ...[
                if (q.approveAllowed)
                  TextButton(
                    onPressed: () {
                      setState(() => _marking = false);
                      _fitAll();
                    },
                    child: const Text('Back'),
                  ),
                TextButton(onPressed: _fitAll, child: const Text('Whole pitch')),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _moved == 0 || ctl.busy
                      ? null
                      : () => ctl.answer((a) => a.markPitch(q.round, Map.of(_points), share: _share)),
                  child: Text(_moved == 0 ? 'Move at least one point' : 'Refit with $_moved moved'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PointRow extends StatelessWidget {
  const _PointRow({
    required this.name,
    required this.state,
    required this.selected,
    required this.onTap,
    required this.onSkip,
  });
  final String name;
  final PitchPoint state;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final (icon, colour) = switch (state) {
      MovedPoint() => (Icons.check_circle, c.grass),
      SkippedPoint() => (Icons.visibility_off_outlined, c.inkMuted),
      FromFitPoint() => (Icons.radio_button_unchecked, c.inkMuted),
    };
    return Material(
      color: selected ? c.grassTint : Colors.transparent,
      borderRadius: BorderRadius.circular(BrandRadius.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(BrandRadius.sm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 18, color: colour),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name[0].toUpperCase() + name.substring(1),
                  style: t.bodyMedium?.copyWith(
                    decoration: state is SkippedPoint ? TextDecoration.lineThrough : null,
                    fontWeight: selected ? FontWeight.w700 : null,
                  ),
                ),
              ),
              TextButton(
                onPressed: onSkip,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: Text(state is SkippedPoint ? 'Use' : 'Can’t see'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PitchPainter extends CustomPainter {
  _PitchPainter({
    required this.viewer,
    required this.question,
    required this.where,
    required this.showPoints,
    required this.selected,
    required this.skipped,
    required this.moved,
    required this.lineColor,
    required this.pointColor,
    required this.selectedColor,
  }) : super(repaint: viewer);

  /// Sizes are in screen pixels: the panorama is shown scaled.
  final TransformationController viewer;
  final PitchQuestion question;
  final Deg Function(String) where;
  final bool showPoints;
  final String? selected;
  final Set<String> skipped;
  final Set<String> moved;
  final Color lineColor, pointColor, selectedColor;

  @override
  void paint(Canvas canvas, Size size) {
    final pano = question.panorama!;
    // The x axis's scale (getMaxScaleOnAxis counts z, which stays 1).
    final m = viewer.value.storage;
    final k = 1 / math.sqrt(m[0] * m[0] + m[1] * m[1]).clamp(0.01, 100);
    Offset px(Deg d) {
      final p = pano.toPx(d);
      return Offset(p.x, p.y);
    }

    final line = Paint()
      ..color = lineColor.withValues(alpha: showPoints ? 0.55 : 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2 * k
      ..strokeJoin = StrokeJoin.round;
    for (final l in question.lines) {
      if (l.length < 2) continue;
      canvas.drawPath(Path()..addPolygon([for (final p in l) px(p)], false), line);
    }
    final goal = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * k;
    for (final g in question.goals) {
      canvas.drawPath(Path()..addPolygon([for (final p in g) px(p)], false), goal);
    }
    if (!showPoints) return;
    for (final name in question.points.keys) {
      if (skipped.contains(name)) continue;
      final at = px(where(name));
      final isSel = name == selected;
      final colour = isSel ? selectedColor : (moved.contains(name) ? lineColor : pointColor);
      canvas.drawCircle(at, (isSel ? 9 : 6) * k, Paint()..color = Colors.black.withValues(alpha: 0.5));
      canvas.drawCircle(
        at,
        (isSel ? 8 : 5) * k,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * k,
      );
      canvas.drawCircle(at, 1.5 * k, Paint()..color = colour);
    }
  }

  @override
  bool shouldRepaint(_PitchPainter old) => true;
}
