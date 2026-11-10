// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// The kit-group check (docs/MAC-APP-PLAN.md, "Kit-group check"): one card
/// per group the engine made, people picked at random from across the game.
/// Tap anyone in the wrong group (or not a player in kit), then answer one
/// question about the groups as a whole. No "which is your team": the
/// camera follows play, not a team.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:osb_core/osb_core.dart';

import '../brand.dart';
import '../game_controller.dart';

enum _Structure { ok, merge, split }

enum _Role { side, keeperOrReferee, notKit }

_Role _proposedRole(String p) => switch (p) {
  'A' || 'B' => _Role.side,
  'keeperOrReferee' => _Role.keeperOrReferee,
  _ => _Role.notKit,
};

class KitsCheck extends StatefulWidget {
  const KitsCheck({super.key, required this.controller, required this.question});
  final GameController controller;
  final KitsQuestion question;

  @override
  State<KitsCheck> createState() => _KitsCheckState();
}

class _KitsCheckState extends State<KitsCheck> {
  final _tapped = <int, Set<String>>{};
  final _roles = <int, _Role>{};
  _Structure _structure = _Structure.ok;
  final _merge = <int>{};
  int? _split;
  bool _share = true;

  KitsQuestion get q => widget.question;

  _Role _role(KitGroup g) => _roles[g.component] ?? _proposedRole(g.proposed);

  bool get _ready => switch (_structure) {
    _Structure.ok => true,
    _Structure.merge => _merge.length >= 2,
    _Structure.split => _split != null,
  };

  void _submit() {
    final changedRoles = _roles.isNotEmpty;
    widget.controller.answer(
      (a) => a.answerKits(
        q.round,
        tapped: _tapped,
        merge: _structure == _Structure.merge ? [_merge] : const [],
        split: _structure == _Structure.split ? _split : null,
        // Only when changed: otherwise the engine keeps its own guess.
        keeperOrReferee: changedRoles
            ? {
                for (final g in q.groups)
                  if (_role(g) == _Role.keeperOrReferee) g.component,
              }
            : null,
        notKit: changedRoles
            ? {
                for (final g in q.groups)
                  if (_role(g) == _Role.notKit) g.component,
              }
            : const {},
        share: _share,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final ctl = widget.controller;
    final groups = [...q.groups]..sort((a, b) => b.people.compareTo(a.people));
    String label(KitGroup g) => 'Group ${groups.indexOf(g) + 1}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Check the kit groups', style: t.titleLarge),
              const SizedBox(height: 4),
              Text(
                'We grouped the people on the pitch by what they wear. Tap anyone in the wrong group, or who isn’t a '
                'player in kit (spectators, subs in bibs, coaches). Then answer the question at the bottom.',
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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
            children: [
              for (final g in groups)
                _GroupCard(
                  folder: ctl.folder!.path,
                  group: g,
                  label: label(g),
                  role: _role(g),
                  tapped: _tapped[g.component] ?? const {},
                  onRole: (r) => setState(() => _roles[g.component] = r),
                  onTap: (id) => setState(() {
                    final s = _tapped.putIfAbsent(g.component, () => {});
                    if (!s.remove(id)) s.add(id);
                  }),
                ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.border)),
          ),
          padding: const EdgeInsets.fromLTRB(28, 14, 28, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('The groups as a whole:', style: t.titleSmall),
              const SizedBox(height: 6),
              RadioGroup<_Structure>(
                groupValue: _structure,
                onChanged: (v) => setState(() => _structure = v ?? _Structure.ok),
                child: Wrap(
                  spacing: 18,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _radio(_Structure.ok, 'Every kit has exactly one group'),
                    _radio(_Structure.merge, 'Two groups are the same kit'),
                    if (q.splitAllowed) _radio(_Structure.split, 'One group has two kits in it'),
                  ],
                ),
              ),
              if (_structure != _Structure.ok) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    Text(
                      _structure == _Structure.merge ? 'Which groups are the same kit?' : 'Which group has two kits?',
                      style: t.bodyMedium,
                    ),
                    for (final g in groups)
                      FilterChip(
                        label: Text(label(g)),
                        selected: _structure == _Structure.merge ? _merge.contains(g.component) : _split == g.component,
                        onSelected: (on) => setState(() {
                          if (_structure == _Structure.merge) {
                            on ? _merge.add(g.component) : _merge.remove(g.component);
                          } else {
                            _split = on ? g.component : null;
                          }
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Switch(value: _share, onChanged: (v) => setState(() => _share = v)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Share these groups and your answers to help improve team detection',
                      style: t.bodyMedium?.copyWith(color: c.inkMuted),
                    ),
                  ),
                  FilledButton(onPressed: !_ready || ctl.busy ? null : _submit, child: const Text('Done')),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _radio(_Structure v, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Radio<_Structure>(value: v),
      GestureDetector(onTap: () => setState(() => _structure = v), child: Text(text)),
    ],
  );
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.folder,
    required this.group,
    required this.label,
    required this.role,
    required this.tapped,
    required this.onRole,
    required this.onTap,
  });
  final String folder;
  final KitGroup group;
  final String label;
  final _Role role;
  final Set<String> tapped;
  final ValueChanged<_Role> onRole;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(label, style: t.titleMedium),
                const SizedBox(width: 10),
                Text(
                  '${group.perMoment.toStringAsFixed(1)} on the pitch at a time'
                  '${tapped.isEmpty ? '' : ' · ${tapped.length} tapped'}',
                  style: t.bodySmall?.copyWith(color: c.inkMuted),
                ),
                const Spacer(),
                SegmentedButton<_Role>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: _Role.side, label: Text('A team')),
                    ButtonSegment(value: _Role.keeperOrReferee, label: Text('Keeper or referee')),
                    ButtonSegment(value: _Role.notKit, label: Text('Not a kit')),
                  ],
                  selected: {role},
                  onSelectionChanged: (s) => onRole(s.first),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final crop in group.crops)
                  GestureDetector(
                    onTap: () => onTap(crop.id),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: tapped.contains(crop.id) ? c.coral : c.border, width: 2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.file(
                              File('$folder/${crop.image}'),
                              height: 96,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 96),
                            ),
                          ),
                          if (tapped.contains(crop.id))
                            Positioned(
                              right: 3,
                              top: 3,
                              child: CircleAvatar(
                                radius: 9,
                                backgroundColor: c.coral,
                                child: Icon(Icons.close, size: 12, color: c.onCoral),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
