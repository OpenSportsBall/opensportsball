// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Keeps the upload queue running when the app is not on screen.
///
/// The queue itself stays in Dart ([UploadService]); this only asks the OS
/// not to stop the app while there is something to send:
///
/// - Android: a `dataSync` foreground service with a progress
///   notification, plus a wake lock and Wi-Fi lock while bytes are moving.
///   The Flutter engine outlives the activity, so swiping the app away
///   doesn't stop it either.
/// - iOS 26+: a `BGContinuedProcessingTask`, which the system shows as a
///   progress item. Older iOS only gets the usual ~30 s after leaving the
///   app.
///
/// Both have to be started while the app is on screen, which is when
/// uploads start anyway (a recording just stopped, or the app was opened).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ui/common.dart' show formatBytes;
import 'upload_service.dart';

/// What the notification (Android) or progress item (iOS) shows.
@immutable
class BackgroundStatus {
  const BackgroundStatus({
    required this.title,
    required this.text,
    required this.permille,
    required this.busy,
  });

  final String title;
  final String text;

  /// Progress of the recordings sent since the keep-alive started, 0..1000.
  final int permille;

  /// Bytes are moving (or about to): Android holds a wake lock and Wi-Fi
  /// lock only then, not while waiting for Wi-Fi.
  final bool busy;

  Map<String, Object?> toMap() => {'title': title, 'text': text, 'permille': permille, 'busy': busy};

  @override
  bool operator ==(Object other) =>
      other is BackgroundStatus &&
      other.title == title &&
      other.text == text &&
      other.permille == permille &&
      other.busy == busy;

  @override
  int get hashCode => Object.hash(title, text, permille, busy);

  @override
  String toString() => 'BackgroundStatus($title, $text, $permille, busy: $busy)';
}

/// The platform side.
abstract class BackgroundRunner {
  /// Starts the keep-alive; false if the OS refused (e.g. the app is not on
  /// screen).
  Future<bool> start(BackgroundStatus status);

  /// False if the keep-alive is no longer running (the OS ended it).
  Future<bool> update(BackgroundStatus status);

  Future<void> stop();
}

class MethodChannelBackgroundRunner implements BackgroundRunner {
  static const _channel = MethodChannel('opensportsball/background_upload');

  @override
  Future<bool> start(BackgroundStatus status) => _call('start', status.toMap());

  @override
  Future<bool> update(BackgroundStatus status) => _call('update', status.toMap());

  @override
  Future<void> stop() => _call('stop', null);

  Future<bool> _call(String method, Object? args) async {
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on MissingPluginException {
      return false; // tests, desktop
    } on PlatformException catch (e) {
      debugPrint('background upload $method: ${e.code} ${e.message}');
      return false;
    }
  }
}

/// Phases worth keeping the app alive for: sending, or about to send once
/// the network is back.
const keepAlivePhases = {
  UploadPhase.starting,
  UploadPhase.uploading,
  UploadPhase.retrying,
  UploadPhase.offline,
  UploadPhase.waitingForWifi,
};

/// Starts, updates and stops the platform keep-alive as the queue changes.
class BackgroundUploads {
  BackgroundUploads({
    required this.uploads,
    BackgroundRunner? runner,
    DateTime Function()? now,
    this.updateInterval = const Duration(seconds: 1),
    this.restartInterval = const Duration(seconds: 30),
  })  : runner = runner ?? MethodChannelBackgroundRunner(),
        _now = now ?? DateTime.now;

  final UploadService uploads;
  final BackgroundRunner runner;
  final DateTime Function() _now;

  /// Most one progress update per this, so a 1 MiB chunk doesn't cross the
  /// platform channel each time.
  final Duration updateInterval;

  /// After the OS refused to start, wait this long before asking again.
  final Duration restartInterval;

  bool _active = false;
  bool _busy = false;
  bool _again = false;
  BackgroundStatus? _sent;
  DateTime? _sentAt;
  DateTime? _refusedAt;

  /// Recordings (by directory) pending at some point since the keep-alive
  /// started, so progress doesn't jump back when one finishes.
  final _session = <String>{};

  bool get active => _active;

  void start() {
    uploads.addListener(_changed);
    _changed();
  }

  /// Try again now even if the OS refused recently (the app came back on
  /// screen).
  void resumed() {
    _refusedAt = null;
    _changed();
  }

  void dispose() {
    uploads.removeListener(_changed);
    if (_active) unawaited(runner.stop());
    _active = false;
  }

  bool get wanted => keepAlivePhases.contains(uploads.phase) && uploads.pending.isNotEmpty;

  void _changed() {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    unawaited(_sync().whenComplete(() {
      _busy = false;
      if (_again) {
        _again = false;
        _changed();
      }
    }));
  }

  Future<void> _sync() async {
    try {
      if (!wanted) {
        if (_active) {
          _active = false;
          _session.clear();
          _sent = null;
          await runner.stop();
        }
        return;
      }
      final now = _now();
      for (final r in uploads.pending) {
        _session.add(r.stored.dir.path);
      }
      final status = statusNow();
      if (!_active) {
        final refused = _refusedAt;
        if (refused != null && now.difference(refused) < restartInterval) return;
        if (await runner.start(status)) {
          _active = true;
          _refusedAt = null;
          _sent = status;
          _sentAt = now;
        } else {
          _refusedAt = now;
        }
        return;
      }
      if (status == _sent) return;
      final sentAt = _sentAt;
      final sameKind = _sent?.title == status.title && _sent?.busy == status.busy;
      if (sameKind && sentAt != null && now.difference(sentAt) < updateInterval) return;
      _sent = status;
      _sentAt = now;
      if (!await runner.update(status)) {
        // The OS ended it (Android's time limit, iOS expiry).
        _active = false;
        _refusedAt = now;
      }
    } on Object catch (e) {
      debugPrint('background upload: $e');
    }
  }

  @visibleForTesting
  BackgroundStatus statusNow() {
    var done = 0, total = 0;
    for (final r in uploads.recordings) {
      if (!_session.contains(r.stored.dir.path)) continue;
      done += r.bytesDone;
      total += r.bytesTotal;
    }
    final count = uploads.pending.length;
    final phase = uploads.phase;
    final title = phase == UploadPhase.uploading || phase == UploadPhase.starting
        ? 'Uploading $count recording${count == 1 ? '' : 's'}'
        : phase.label;
    return BackgroundStatus(
      title: title,
      text: total == 0 ? '' : '${formatBytes(done)} of ${formatBytes(total)}',
      permille: total == 0 ? 0 : (done * 1000 ~/ total).clamp(0, 1000),
      busy: phase == UploadPhase.uploading ||
          phase == UploadPhase.retrying ||
          phase == UploadPhase.starting,
    );
  }
}
