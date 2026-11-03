// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// The upload queue: sends this phone's finished recordings to the
/// backend (docs/API.md, "Routes for phones") while the app is open.
///
/// Each recording goes to its own account: one made as Main to this
/// phone's account, with its device token; one made as Secondary to the
/// Main phone's account, with the recording grant Main gave for that game.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../model.dart';
import '../role.dart';
import '../session/activity.dart';
import '../storage/store.dart';
import 'account.dart';
import 'network.dart';
import 'upload_state.dart';

enum UploadPhase {
  starting('Starting'),
  notLinked('This phone is not linked to an account'),
  unlinked('This phone was unlinked; link it again'),
  waitingForGrant('Waiting for upload permission from the Main phone'),
  grantExpired('Upload permission from the Main phone expired; pair with it again'),
  off('Uploading to the cloud is off'),
  paused('Paused'),
  recording('Paused while recording'),
  offline('No internet connection'),
  waitingForWifi('Waiting for Wi-Fi'),
  uploading('Uploading'),
  retrying('Connection problem, retrying'),
  failed('Some recordings could not be uploaded'),
  idle('Up to date');

  const UploadPhase(this.label);
  final String label;
}

/// Result of one pass over the queue.
enum PassResult {
  /// Everything uploadable is uploaded.
  done,

  /// Some recordings hit errors that retrying soon won't fix.
  someFailed,

  /// A network or server error; try again after a backoff.
  retry,

  /// Not allowed to upload right now (recording, network, no account or
  /// grant for the recordings waiting...).
  blocked,

  /// Stopped part way because a condition changed.
  interrupted,

  /// The API rejected the device token.
  unauthorized,
}

/// Where one recording uploads, and with which token.
class UploadTarget {
  const UploadTarget({required this.apiUrl, required this.token, required this.accountId, required this.grant});

  final String apiUrl;
  final String token;
  final String accountId;

  /// A recording grant from another phone's account, not this phone's
  /// own device token.
  final bool grant;
}

/// One recording's place in the queue.
class RecordingUpload {
  RecordingUpload({required this.stored, required this.state, this.manifestSha256});

  final StoredRecording stored;
  UploadState state;

  /// Hash of this phone's upload document on disk (Main's manifest.json or
  /// another phone's report.json), null if none yet.
  final String? manifestSha256;

  String? currentFile;
  int currentFileSent = 0;
  int currentFileBytes = 0;
  String? error;

  /// Where it uploads; null while [blocked].
  UploadTarget? target;

  /// Why it cannot upload yet: no account, or no grant from Main.
  UploadPhase? blocked;

  LocalRecording get recording => stored.recording;
  bool get isMain => recording.role == DeviceRole.main;
  bool get hasManifest => manifestSha256 != null;
  bool get manifestUploaded => hasManifest && state.manifestSha256 == manifestSha256;
  bool get manifestPending => !manifestUploaded;

  int get filesTotal => recording.segments.length;
  int get filesDone => recording.segments.where((s) => state.segmentDone(s.fileName)).length;
  int get bytesTotal => stored.totalBytes;

  int get bytesDone {
    var sum = 0;
    for (final s in recording.segments) {
      final st = state.segments[s.fileName];
      if (s.fileName == currentFile && st?.done != true) {
        sum += currentFileSent;
      } else if (st != null) {
        sum += st.bytesUploaded(s.bytes);
      }
    }
    return sum;
  }

  bool get complete => filesDone == filesTotal && !manifestPending;
}

class _Unauthorized implements Exception {}

class _Interrupted implements Exception {}

/// Presigned URLs were rejected (expired): ask the API for fresh ones.
class _Expired implements Exception {}

class _Transient implements Exception {
  _Transient(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Permanent implements Exception {
  _Permanent(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Wait before retry number [attempt] (0-based): 5 s doubling to 10 min.
Duration backoffDelay(int attempt) =>
    Duration(seconds: math.min(600, 5 * math.pow(2, math.min(attempt, 10)).toInt()));

class UploadService extends ChangeNotifier {
  UploadService({
    required this.store,
    required this.account,
    required this.client,
    required this.network,
    DeviceActivity? activity,
    Future<void> Function(bool on)? keepScreenOn,
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
    this.chunkBytes = 1 << 20,
    this.rescanInterval = const Duration(seconds: 30),
    this.stallTimeout = const Duration(minutes: 2),
  })  : activity = activity ?? DeviceActivity.instance,
        _keepScreenOn = keepScreenOn ?? ((_) async {}),
        _delay = delay ?? ((d) => Future<void>.delayed(d)),
        _now = now ?? DateTime.now;

  final AppStore store;
  final AccountManager account;
  final http.Client client;
  final NetworkMonitor network;
  final DeviceActivity activity;
  final Future<void> Function(bool on) _keepScreenOn;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;

  /// Bytes read from disk per write to the socket (memory use per upload).
  final int chunkBytes;

  /// How often an idle queue looks for newly finished recordings.
  final Duration rescanInterval;

  /// A part that sends nothing for this long is cut off and retried (a
  /// Wi-Fi network that is still "connected" but out of range).
  final Duration stallTimeout;

  static const _apiTimeout = Duration(seconds: 60);
  static const _partTimeout = Duration(minutes: 30);

  UploadPhase _phase = UploadPhase.starting;
  List<RecordingUpload> _recordings = const [];
  NetworkKind _net = NetworkKind.offline;
  bool _paused = false;
  bool _mobileOverride = false;
  String? _error;
  DateTime? _retryAt;
  bool _running = false;
  bool _passing = false;
  bool _disposed = false;
  bool _awake = false;
  Completer<void>? _kick;

  /// Completing it aborts the part being sent.
  Completer<void>? _abortPut;
  StreamSubscription<NetworkKind>? _netSub;

  UploadPhase get phase => _phase;

  /// This phone's recordings, oldest first.
  List<RecordingUpload> get recordings => _recordings;
  NetworkKind get networkKind => _net;
  bool get paused => _paused;
  bool get enabled => store.uploadSettings.enabled;
  bool get wifiOnly => store.uploadSettings.wifiOnly;
  bool get mobileOverride => _mobileOverride;

  /// The last connection / server problem, while retrying.
  String? get error => _error;
  DateTime? get retryAt => _retryAt;

  List<RecordingUpload> get pending => [for (final r in _recordings) if (!r.complete) r];
  int get pendingBytesTotal => pending.fold(0, (s, r) => s + r.bytesTotal);
  int get pendingBytesDone => pending.fold(0, (s, r) => s + r.bytesDone);

  /// Waiting only because the phone is on mobile data.
  bool get blockedByMobileData =>
      enabled && _net == NetworkKind.metered && wifiOnly && !_mobileOverride && pending.isNotEmpty;

  // ---- Controls ----

  void start() {
    if (_running || _disposed) return;
    _running = true;
    activity.addListener(_onActivity);
    account.addListener(kick);
    _netSub = network.changes.listen((k) {
      _net = k;
      _stopIfBlocked();
      kick();
    }, onError: (Object e) => debugPrint('connectivity: $e'));
    unawaited(_loop());
  }

  /// Look again now (new recording, setting changed, app resumed).
  void kick() {
    final k = _kick;
    if (k != null && !k.isCompleted) k.complete();
  }

  void setPaused(bool paused) {
    _paused = paused;
    _stopIfBlocked();
    _notify();
    kick();
  }

  /// Off stops the upload in progress; nothing is sent until it is on again.
  Future<void> setEnabled(bool on) async {
    await store.saveUploadSettings(store.uploadSettings.copyWith(enabled: on));
    _stopIfBlocked();
    _notify();
    kick();
  }

  Future<void> setWifiOnly(bool on) async {
    await store.saveUploadSettings(store.uploadSettings.copyWith(wifiOnly: on));
    _notify();
    kick();
  }

  /// Upload on mobile data until the queue is empty (or the app restarts).
  void useMobileDataOnce() {
    _mobileOverride = true;
    _notify();
    kick();
  }

  void cancelMobileData() {
    _mobileOverride = false;
    _stopIfBlocked();
    _notify();
    kick();
  }

  /// Re-reads recordings from disk for the UI without uploading.
  Future<void> refresh() async {
    if (_passing) return;
    await _scan();
    _notify();
  }

  // ---- Loop ----

  Future<void> _loop() async {
    var attempt = 0;
    while (!_disposed) {
      PassResult result;
      try {
        result = await runPass();
      } on Object catch (e, st) {
        debugPrint('upload pass crashed: $e\n$st');
        _error = '$e';
        result = PassResult.retry;
      }
      if (_disposed) break;
      switch (result) {
        case PassResult.retry:
          final wait = backoffDelay(attempt++);
          _retryAt = _now().add(wait);
          _setPhase(UploadPhase.retrying);
          await _waitForKick(wait);
          _retryAt = null;
        case PassResult.interrupted:
          attempt = 0;
        case PassResult.done:
        case PassResult.someFailed:
        case PassResult.blocked:
        case PassResult.unauthorized:
          attempt = 0;
          await _waitForKick(
              result == PassResult.someFailed ? rescanInterval * 4 : rescanInterval);
      }
    }
  }

  Future<void> _waitForKick(Duration d) async {
    final k = _kick = Completer<void>();
    unawaited(_delay(d).then((_) {
      if (!k.isCompleted) k.complete();
    }));
    await k.future;
  }

  void _onActivity() {
    if (_awake) unawaited(_safeKeepScreenOn(true)); // a camera screen closing turns it off
    if (activity.recording) {
      _stopIfBlocked();
      _notify();
    } else {
      kick();
    }
  }

  // ---- One pass ----

  /// What stops all uploads. Accounts and grants are per recording
  /// ([_target]).
  UploadPhase? _blockedBy() {
    if (_disposed) return UploadPhase.paused;
    if (!enabled) return UploadPhase.off;
    if (_paused) return UploadPhase.paused;
    if (activity.recording) return UploadPhase.recording;
    if (_net == NetworkKind.offline) return UploadPhase.offline;
    if (_net == NetworkKind.metered && wifiOnly && !_mobileOverride) {
      return UploadPhase.waitingForWifi;
    }
    return null;
  }

  bool _allowed() => _blockedBy() == null;

  /// Uploads aren't allowed any more: say so now and cut off the part being
  /// sent, instead of waiting for it (a stalled socket never asks again).
  void _stopIfBlocked() {
    final blocked = _blockedBy();
    if (blocked == null) return;
    final abort = _abortPut;
    if (abort != null && !abort.isCompleted) abort.complete();
    if (_passing) _setPhase(blocked);
  }

  void _checkAllowed() {
    if (!_allowed()) throw _Interrupted();
  }

  /// Uploads everything allowed right now, oldest recording first.
  @visibleForTesting
  Future<PassResult> runPass() async {
    if (_passing) return PassResult.blocked;
    _passing = true;
    try {
      try {
        _net = await network.current();
      } on Object catch (e) {
        debugPrint('connectivity check failed: $e');
      }
      await _scan();
      if (_net != NetworkKind.offline && enabled) {
        // A tiny request, so mobile data is fine: Main binds the tickets it
        // handed over, before uploading the manifest that names that
        // Secondary. Nothing to send if it handed none over.
        await account.redeemPending();
      }
      final blocked = _blockedBy();
      if (blocked != null) {
        _setPhase(blocked);
        return PassResult.blocked;
      }
      var failed = false, deviceRejected = false;
      UploadPhase? waiting;
      for (final u in _recordings) {
        if (u.complete || !u.recording.stopped) continue;
        if (u.recording.role == DeviceRole.secondary) {
          try {
            await _redeemTicket(u.recording.gameId);
          } on _Transient catch (e) {
            _error = e.message;
            u.error = e.message;
            return PassResult.retry;
          }
        }
        await _target(u);
        final target = u.target;
        if (target == null) {
          waiting ??= u.blocked;
          continue;
        }
        try {
          await _uploadRecording(u, target);
          u.error = null;
        } on _Unauthorized {
          if (target.grant) {
            await account.markGrantRejected(u.recording.gameId);
          } else {
            account.markRevoked();
            deviceRejected = true;
          }
          await _target(u);
          waiting ??= u.blocked;
        } on _Interrupted {
          _setPhase(_blockedBy() ?? UploadPhase.starting);
          return PassResult.interrupted;
        } on _Transient catch (e) {
          _error = e.message;
          u.error = e.message;
          return PassResult.retry;
        } on _Permanent catch (e) {
          u.error = e.message;
          failed = true;
          await _saveQuietly(u, error: e.message);
        } finally {
          u.currentFile = null;
          u.currentFileSent = 0;
          _notify();
        }
      }
      _error = null;
      _mobileOverride = false; // one-time: nothing more to send right now
      // A phone that records as Main restocks grant tickets for the next
      // pairing without signal. No request when the stock is full.
      if (!deviceRejected && _recordings.any((u) => u.isMain)) await account.refillTickets();
      if (deviceRejected) {
        _setPhase(UploadPhase.unlinked);
        return PassResult.unauthorized;
      }
      _setPhase(failed ? UploadPhase.failed : waiting ?? UploadPhase.idle);
      if (failed) return PassResult.someFailed;
      return waiting != null ? PassResult.blocked : PassResult.done;
    } finally {
      _passing = false;
    }
  }

  /// A grant Main handed over as a ticket, without signal, is bound to this
  /// phone and game before its first upload. A refused ticket counts as a
  /// rejected grant: a new one from Main replaces it.
  Future<void> _redeemTicket(String gameId) async {
    final g = await account.grantFor(gameId);
    if (g == null || !g.unredeemed || g.rejected) return;
    try {
      await account.redeemGrant(g, deviceId: account.store.identity.deviceId);
    } on LinkException catch (e) {
      if (e.offline) throw _Transient(e.message);
      debugPrint('grant ticket refused: $e');
      await account.markGrantRejected(gameId);
    }
  }

  /// Where [rec] uploads, or why it cannot yet (no account, no grant).
  Future<(UploadTarget?, UploadPhase?)> _targetFor(LocalRecording rec) async {
    if (rec.role == DeviceRole.main) {
      final link = account.link;
      if (link == null) return (null, UploadPhase.notLinked);
      if (account.revoked) return (null, UploadPhase.unlinked);
      return (
        UploadTarget(apiUrl: link.apiUrl, token: link.deviceToken, accountId: link.accountId, grant: false),
        null
      );
    }
    final g = await account.grantFor(rec.gameId);
    if (g == null) return (null, UploadPhase.waitingForGrant);
    if (!g.usableAt(_now())) return (null, UploadPhase.grantExpired);
    return (UploadTarget(apiUrl: g.apiUrl, token: g.token, accountId: g.accountId, grant: true), null);
  }

  Future<void> _target(RecordingUpload u) async {
    final (t, blocked) = await _targetFor(u.recording);
    u
      ..target = t
      ..blocked = blocked;
  }

  Future<void> _scan() async {
    final previous = {for (final r in _recordings) r.stored.dir.path: r};
    final list = await store.listRecordings();
    final out = <RecordingUpload>[];
    for (final s in list.reversed) {
      if (s.recording.device.deviceId != store.identity.deviceId) continue;
      UploadState state;
      try {
        final json = await store.readUploadJson(s.dir);
        state = json == null ? UploadState() : UploadState.fromJson(json);
      } on Object catch (e) {
        debugPrint('bad upload.json in ${s.dir.path}: $e');
        state = UploadState();
      }
      final (target, blocked) = await _targetFor(s.recording);
      final accountId = target?.accountId;
      if (state.accountId != null && accountId != null && state.accountId != accountId) {
        state = UploadState(); // now uploads to another account: start over
      }
      String? manifestSha;
      try {
        if (await store.ensureUploadDocument(s)) {
          manifestSha =
              sha256.convert(await File('${s.dir.path}/${s.documentName}').readAsBytes()).toString();
        }
      } on Object catch (e) {
        debugPrint('upload document for ${s.dir.path}: $e');
      }
      final u = RecordingUpload(stored: s, state: state, manifestSha256: manifestSha)
        ..target = target
        ..blocked = blocked;
      u.error = previous[s.dir.path]?.error ?? state.lastError;
      out.add(u);
    }
    _recordings = out;
  }

  Future<void> _save(RecordingUpload u) {
    u.state.accountId = u.target?.accountId ?? u.state.accountId;
    return store.writeUploadJson(u.stored.dir, u.state.toJson());
  }

  Future<void> _saveQuietly(RecordingUpload u, {String? error}) async {
    u.state.lastError = error;
    try {
      await _save(u);
    } on Object catch (_) {}
  }

  Future<void> _uploadRecording(RecordingUpload u, UploadTarget target) async {
    final rec = u.recording;
    final segments = [...rec.segments]..sort((a, b) => a.index.compareTo(b.index));
    final manifestToSend = u.hasManifest && !u.manifestUploaded;
    if (!manifestToSend && segments.every((s) => u.state.segmentDone(s.fileName))) return;
    _setPhase(UploadPhase.uploading);
    String? manifestError;
    if (manifestToSend) {
      _checkAllowed();
      try {
        await _uploadManifest(u, target);
      } on _Permanent catch (e) {
        manifestError = '${u.isMain ? 'Manifest' : 'Segment list'}: ${e.message}';
      }
    }
    for (final seg in segments) {
      if (u.state.segmentDone(seg.fileName)) continue;
      _checkAllowed();
      await _uploadSegment(u, seg, target);
    }
    if (manifestError != null) throw _Permanent(manifestError);
    if (u.state.lastError != null) {
      u.state.lastError = null;
      await _save(u);
    }
  }

  /// Main's manifest, or another phone's report of its own segments.
  Future<void> _uploadManifest(RecordingUpload u, UploadTarget target) async {
    final rec = u.recording;
    final bytes = await File('${u.stored.dir.path}/${u.stored.documentName}').readAsBytes();
    final sha = sha256.convert(bytes).toString();
    final res = await _api(
      target,
      'PUT',
      '/games/${Uri.encodeComponent(rec.gameId)}/recordings/'
          '${Uri.encodeComponent(rec.recordingId)}/${u.isMain ? 'manifest' : 'report'}',
      utf8.decode(bytes),
    );
    u.state.manifestSha256 = sha;
    u.state.manifestStatus = res['status'] as String?;
    await _save(u);
    _notify();
  }

  Future<void> _uploadSegment(RecordingUpload u, SegmentRecord seg, UploadTarget target) async {
    final rec = u.recording;
    final file = File('${u.stored.dir.path}/${seg.fileName}');
    final int length;
    try {
      length = await file.length();
    } on FileSystemException {
      throw _Permanent('${seg.fileName} is missing from this phone');
    }
    if (length != seg.bytes) {
      throw _Permanent('${seg.fileName} is ${seg.bytes} bytes in recording.json but $length on disk');
    }
    final st = u.state.segment(seg.fileName);
    u.currentFile = seg.fileName;
    u.currentFileBytes = length;
    u.currentFileSent = st.bytesUploaded(length);
    _notify();

    var refreshes = 0;
    outer:
    while (true) {
      _checkAllowed();
      final start = await _api(target, 'POST', '/uploads', {
        'gameId': rec.gameId,
        'recordingId': rec.recordingId,
        'fileName': seg.fileName,
        'bytes': seg.bytes,
        'sha256': seg.sha256,
      });
      if (start['alreadyUploaded'] == true) {
        st
          ..done = true
          ..parts.clear()
          ..uploadId = null;
        await _save(u);
        return;
      }
      final uploadId = start['uploadId'], partSize = start['partSizeBytes'];
      if (uploadId is! String || partSize is! int || partSize <= 0) {
        throw _Transient('The server sent an unexpected answer to POST /uploads');
      }
      final toDo = <int, String>{
        for (final p in (start['parts'] as List? ?? const []).cast<Map<String, Object?>>())
          p['partNumber'] as int: p['url'] as String,
      };
      final completed = <int, String>{
        for (final p in (start['completedParts'] as List? ?? const []).cast<Map<String, Object?>>())
          p['partNumber'] as int: p['etag'] as String,
      };
      final expiresAt = DateTime.tryParse(start['urlsExpireAt'] as String? ?? '');

      if (st.uploadId != uploadId || st.partSizeBytes != partSize) {
        st
          ..parts.clear()
          ..uploadId = uploadId
          ..partSizeBytes = partSize;
      }
      // The server knows what S3 has. Keep a local ETag only for parts the
      // server isn't asking for again.
      st.parts.removeWhere((n, _) => toDo.containsKey(n));
      st.parts.addAll(completed);
      await _save(u);
      u.currentFileSent = st.bytesUploaded(length);
      _notify();

      final partCount = (length + partSize - 1) ~/ partSize;
      for (final n in toDo.keys.toList()..sort()) {
        if (n < 1 || n > partCount) throw _Permanent('Server asked for part $n of $partCount');
        if (expiresAt != null && _now().isAfter(expiresAt.subtract(const Duration(minutes: 2)))) {
          if (refreshes++ >= 3) throw _Transient('Upload links keep expiring; check the phone clock');
          continue outer;
        }
        _checkAllowed();
        final from = (n - 1) * partSize, to = math.min(n * partSize, length);
        final base = st.bytesUploaded(length);
        try {
          final etag = await _putPart(file, toDo[n]!, from, to, (sent) {
            u.currentFileSent = base + sent;
            _notify();
          });
          st.parts[n] = etag;
        } on _Expired {
          if (refreshes++ >= 3) throw _Transient('Storage keeps rejecting the upload links');
          continue outer;
        }
        await _save(u);
        u.currentFileSent = st.bytesUploaded(length);
        _notify();
      }

      final missing = [for (var n = 1; n <= partCount; n++) if (!st.parts.containsKey(n)) n];
      if (missing.isNotEmpty) {
        st.parts.clear();
        await _save(u);
        throw _Transient('Parts $missing are not uploaded; starting the file again');
      }
      try {
        await _api(target, 'POST', '/uploads/complete', {
          'gameId': rec.gameId,
          'recordingId': rec.recordingId,
          'fileName': seg.fileName,
          'uploadId': uploadId,
          'parts': [
            for (var n = 1; n <= partCount; n++) {'partNumber': n, 'etag': st.parts[n]},
          ],
        });
      } on _Permanent {
        // Our ETags disagree with S3; next time trust the server's list.
        st.parts.clear();
        await _save(u);
        rethrow;
      }
      st
        ..done = true
        ..parts.clear()
        ..uploadId = null;
      await _save(u);
      return;
    }
  }

  /// PUTs bytes [from, to) of [file] to a presigned URL; returns the ETag.
  Future<String> _putPart(
      File file, String url, int from, int to, void Function(int sent) onSent) async {
    final abort = _abortPut = Completer<void>();
    var stalled = false;
    Timer? watchdog;
    void watch() {
      watchdog?.cancel();
      watchdog = Timer(stallTimeout, () {
        stalled = true;
        if (!abort.isCompleted) abort.complete();
      });
    }

    final req = _FileRangeRequest(
      Uri.parse(url),
      file: file,
      from: from,
      to: to,
      chunkBytes: chunkBytes,
      onSent: (sent) {
        watch();
        onSent(sent);
      },
      check: _checkAllowed,
      abortTrigger: abort.future,
    );
    final http.Response res;
    try {
      watch();
      res = await http.Response.fromStream(await client.send(req).timeout(_partTimeout));
    } on _Interrupted {
      rethrow;
    } on FileSystemException catch (e) {
      throw _Permanent('Could not read ${file.uri.pathSegments.last}: ${e.message}');
    } on Object catch (e) {
      if (!_allowed()) throw _Interrupted(); // cut off on purpose
      if (stalled) throw _Transient('The connection stalled');
      throw _Transient(_networkMessage(e));
    } finally {
      watchdog?.cancel();
      if (identical(_abortPut, abort)) _abortPut = null;
    }
    if (res.statusCode == 403) throw _Expired();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _Transient('Storage answered ${res.statusCode}');
    }
    final etag = res.headers['etag'];
    if (etag == null || etag.isEmpty) throw _Transient('Storage did not return an ETag');
    return etag;
  }

  /// Calls the API with the recording's token. Maps failures to the
  /// retry / permanent / unauthorized exceptions.
  Future<Map<String, Object?>> _api(
      UploadTarget target, String method, String path, Object body) async {
    final req = http.Request(method, apiUri(target.apiUrl, path))
      ..headers['Authorization'] = 'Bearer ${target.token}'
      ..headers['Content-Type'] = 'application/json'
      ..body = body is String ? body : jsonEncode(body);
    final http.Response res;
    try {
      res = await http.Response.fromStream(await client.send(req).timeout(_apiTimeout));
    } on Object catch (e) {
      throw _Transient(_networkMessage(e));
    }
    final code = res.statusCode;
    if (code == 401) throw _Unauthorized();
    if (code >= 200 && code < 300) {
      if (res.body.trim().isEmpty) return const {};
      try {
        return (jsonDecode(res.body) as Map).cast();
      } on Object {
        throw _Transient('The server sent an unexpected answer to $method $path');
      }
    }
    final msg = '$method ${path.split('/').take(2).join('/')} failed ($code${serverMessage(res)})';
    if (code >= 500 || code == 429 || code == 408) throw _Transient(msg);
    throw _Permanent(msg);
  }

  // ---- Status ----

  void _setPhase(UploadPhase p) {
    final wantAwake = p == UploadPhase.uploading;
    if (wantAwake != _awake) {
      _awake = wantAwake;
      // Leave the screen on if a camera screen wants it on.
      if (wantAwake || !activity.cameraOpen) unawaited(_safeKeepScreenOn(wantAwake));
    }
    if (_phase != p) {
      _phase = p;
      _notify();
    }
  }

  Future<void> _safeKeepScreenOn(bool on) async {
    try {
      await _keepScreenOn(on);
    } on Object catch (e) {
      debugPrint('keep screen on failed: $e');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    kick();
    activity.removeListener(_onActivity);
    account.removeListener(kick);
    unawaited(_netSub?.cancel());
    if (_awake) unawaited(_safeKeepScreenOn(false));
    super.dispose();
  }
}

String _networkMessage(Object e) => switch (e) {
      TimeoutException() => 'The connection timed out',
      SocketException() => 'Could not reach the server',
      HandshakeException() => 'Secure connection failed',
      http.ClientException(:final message) => 'Connection problem: $message',
      _ => 'Connection problem: $e',
    };

/// A PUT whose body is a byte range of a file, read in chunks with
/// [RandomAccessFile] so a 64 MiB part never sits in memory whole.
class _FileRangeRequest extends http.BaseRequest with http.Abortable {
  _FileRangeRequest(
    Uri url, {
    required this.file,
    required this.from,
    required this.to,
    required this.chunkBytes,
    required this.onSent,
    required this.check,
    this.abortTrigger,
  }) : super('PUT', url) {
    contentLength = to - from;
  }

  final File file;
  final int from;
  final int to;
  final int chunkBytes;
  final void Function(int sent) onSent;
  final void Function() check;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_read());
  }

  Stream<List<int>> _read() async* {
    final raf = await file.open();
    try {
      await raf.setPosition(from);
      var pos = from;
      while (pos < to) {
        check();
        final want = math.min(chunkBytes, to - pos);
        final bytes = await raf.read(want);
        if (bytes.length != want) {
          throw FileSystemException('file is shorter than expected', file.path);
        }
        pos += want;
        yield bytes;
        onSent(pos - from);
      }
    } finally {
      await raf.close();
    }
  }
}
