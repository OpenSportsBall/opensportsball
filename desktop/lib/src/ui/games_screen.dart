// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:osb_core/osb_core.dart';

import '../auth.dart';
import '../brand.dart';
import '../game_controller.dart';
import '../services.dart';
import 'game_pane.dart';
import 'settings_dialog.dart';

String formatWhen(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '${months[l.month - 1]} ${l.day}, ${l.year} · $h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}

class GamesScreen extends StatefulWidget {
  const GamesScreen({
    super.key,
    required this.session,
    required this.auth,
    required this.settings,
    required this.client,
  });
  final Session session;
  final AuthController auth;
  final Settings settings;
  final http.Client client;

  @override
  State<GamesScreen> createState() => GamesScreenState();
}

class GamesScreenState extends State<GamesScreen> {
  List<GameSummary>? _games;
  String? _error;
  bool _loading = false;
  String? _selected;

  /// Kept while the app runs, so a download or a run carries on while
  /// another game is shown.
  final _controllers = <String, GameController>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> shutdown() async {
    await Future.wait([for (final c in _controllers.values) c.shutdown()]);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final g = await widget.session.games();
      setState(() => _games = g);
      // A game opened while it was uploading (or that failed to load) is
      // asked about again, so the list and the game say the same thing.
      for (final c in _controllers.values) {
        if (c.awaitingUpload || (c.game == null && c.error != null)) unawaited(c.open());
      }
    } on SignedOut {
      widget.auth.signedOut();
    } on OsbException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  GameController _controller(GameSummary g) => _controllers.putIfAbsent(g.gameId, () {
    final c = GameController(
      summary: g,
      session: widget.session,
      settings: widget.settings,
      onSignedOut: widget.auth.signedOut,
    );
    c.addListener(_changed);
    Future.microtask(c.open);
    return c;
  });

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The game whose engine is working, if any: one at a time, the engine
  /// uses the whole Mac.
  GameController? get _engineBusy => _controllers.values
      .where((c) => c.phase == Phase.preparing || c.phase == Phase.running || c.phase == Phase.paused)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final games = _games;
    final selected = games?.where((g) => g.gameId == _selected).firstOrNull;
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 300,
            child: Material(
              color: c.surfaceSunken,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 36, 8, 8),
                    child: Row(
                      children: [
                        Expanded(child: Text('Games', style: t.titleLarge)),
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: _loading ? null : _load,
                          icon: const Icon(Icons.refresh),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Account',
                          icon: const Icon(Icons.account_circle_outlined),
                          onSelected: (v) async {
                            if (v == 'settings') {
                              await showDialog<void>(
                                context: context,
                                builder: (_) => SettingsDialog(settings: widget.settings),
                              );
                            } else if (v == 'signout') {
                              if (_engineBusy != null) return;
                              await widget.auth.signOut();
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(enabled: false, child: Text(widget.session.email ?? 'Signed in')),
                            const PopupMenuItem(value: 'settings', child: Text('Settings…')),
                            const PopupMenuItem(value: 'signout', child: Text('Sign out')),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(_error!, style: t.bodyMedium?.copyWith(color: c.coral)),
                    ),
                  if (games == null && _error == null) const LinearProgressIndicator(),
                  if (games != null && games.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'No games yet. Record one with the phone app.',
                        style: t.bodyMedium?.copyWith(color: c.inkMuted),
                      ),
                    ),
                  if (games != null)
                    Expanded(
                      child: ListView(
                        children: [
                          for (final g in games)
                            _GameTile(
                              game: g,
                              selected: g.gameId == _selected,
                              controller: _controllers[g.gameId],
                              onTap: () => setState(() => _selected = g.gameId),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          VerticalDivider(width: 1, color: c.border),
          Expanded(
            child: selected == null
                ? Center(
                    child: Text(
                      'Choose a game to process it on this Mac.',
                      style: t.bodyLarge?.copyWith(color: c.inkMuted),
                    ),
                  )
                : Builder(
                    builder: (context) {
                      final ctl = _controller(selected);
                      final busy = _engineBusy;
                      return GamePane(
                        key: ValueKey(selected.gameId),
                        controller: ctl,
                        otherBusy: busy != null && busy != ctl ? busy.summary : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({required this.game, required this.selected, required this.onTap, this.controller});
  final GameSummary game;
  final bool selected;
  final VoidCallback onTap;
  final GameController? controller;

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final ctl = controller;
    return ListenableBuilder(
      listenable: ctl ?? ValueNotifier(0),
      builder: (context, _) {
        final status = switch (ctl?.phase) {
          Phase.downloading => 'Downloading',
          Phase.preparing => 'Getting ready',
          Phase.questions => 'Needs your check',
          Phase.running => 'Processing',
          Phase.paused => 'Paused',
          Phase.done => 'Video ready',
          // The opened game knows more recently than the list does.
          _ => (ctl?.game != null ? !ctl!.awaitingUpload : game.status == 'ready')
              ? 'Ready to process'
              : 'Uploading from the phones',
        };
        return ListTile(
          selected: selected,
          selectedTileColor: c.grassTint,
          onTap: onTap,
          title: Text(formatWhen(game.when), style: t.titleSmall),
          subtitle: Text(status, style: t.bodySmall?.copyWith(color: c.inkMuted)),
          trailing: (ctl?.busy ?? false)
              ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : null,
        );
      },
    );
  }
}
