// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/// Messages exchanged between the Main and Secondary phones over BLE.
/// Encoded as JSON, then split into frames by `framing.dart`.
///
/// Main -> Secondary: welcome, pong, prepare, start, stop.
/// Secondary -> Main: hello, ping, clock, prepared, started, stopped,
/// segment, status, error.
///
/// Commands that change recording state (prepare, start, stop) are retried
/// by Main until acknowledged, so Secondary must handle duplicates.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../model.dart';

sealed class Msg {
  const Msg();

  String get type;

  Map<String, Object?> fields();

  Uint8List encode() => utf8.encode(jsonEncode({'t': type, ...fields()}));

  static Msg decode(Uint8List bytes) {
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    return switch (j['t']) {
      'hello' => Hello(DeviceIdentity.fromJson(_map(j['device']))),
      'welcome' => Welcome(
          gameId: j['gameId'] as String,
          mainDeviceId: j['mainDeviceId'] as String,
          settings: RecordingSettings.fromJson(_map(j['settings'])),
        ),
      'ping' => Ping(id: j['id'] as int, t1: j['t1'] as int),
      'pong' =>
        Pong(id: j['id'] as int, t1: j['t1'] as int, t2: j['t2'] as int),
      'clock' => ClockReport(ClockEstimate.fromJson(_map(j['estimate']))),
      'prepare' => Prepare(j['recordingId'] as String),
      'prepared' => Prepared(
          recordingId: j['recordingId'] as String,
          video: j['video'] == null ? null : VideoInfo.fromJson(_map(j['video'])),
          error: j['error'] as String?,
        ),
      'start' => Start(
          recordingId: j['recordingId'] as String,
          atMainMs: j['atMainMs'] as int,
        ),
      'started' => Started(
          recordingId: j['recordingId'] as String,
          startedAtDeviceMs: j['startedAtDeviceMs'] as int,
        ),
      'stop' => Stop(j['recordingId'] as String),
      'stopped' => Stopped(
          recordingId: j['recordingId'] as String,
          segmentCount: j['segmentCount'] as int,
        ),
      'segment' => SegmentMsg(
          recordingId: j['recordingId'] as String,
          segment: SegmentRecord.fromJson(_map(j['segment'])),
        ),
      'status' => StatusMsg(
          batteryPercent: j['batteryPercent'] as int,
          charging: j['charging'] as bool,
          freeStorageBytes: j['freeStorageBytes'] as int,
          thermalState: j['thermalState'] as String,
          recordingId: j['recordingId'] as String?,
          segmentCount: j['segmentCount'] as int,
          elapsedMs: j['elapsedMs'] as int,
        ),
      'error' =>
        ErrorMsg(code: j['code'] as String, message: j['message'] as String),
      _ => throw FormatException('unknown message type: ${j['t']}'),
    };
  }

  static Map<String, Object?> _map(Object? o) => (o as Map).cast();
}

/// Secondary introduces itself after connecting (and after reconnecting).
class Hello extends Msg {
  const Hello(this.device);
  final DeviceIdentity device;
  @override
  String get type => 'hello';
  @override
  Map<String, Object?> fields() => {'device': device.toJson()};
}

/// Main's reply to [Hello]: which game this is and how to record.
class Welcome extends Msg {
  const Welcome({
    required this.gameId,
    required this.mainDeviceId,
    required this.settings,
  });
  final String gameId;
  final String mainDeviceId;
  final RecordingSettings settings;
  @override
  String get type => 'welcome';
  @override
  Map<String, Object?> fields() => {
        'gameId': gameId,
        'mainDeviceId': mainDeviceId,
        'settings': settings.toJson(),
      };
}

/// Clock sync request. [t1] is Secondary's clock when sent.
class Ping extends Msg {
  const Ping({required this.id, required this.t1});
  final int id;
  final int t1;
  @override
  String get type => 'ping';
  @override
  Map<String, Object?> fields() => {'id': id, 't1': t1};
}

/// Clock sync reply. [t2] is Main's clock when the ping arrived.
class Pong extends Msg {
  const Pong({required this.id, required this.t1, required this.t2});
  final int id;
  final int t1;
  final int t2;
  @override
  String get type => 'pong';
  @override
  Map<String, Object?> fields() => {'id': id, 't1': t1, 't2': t2};
}

/// Secondary's current clock-offset estimate, for the manifest.
class ClockReport extends Msg {
  const ClockReport(this.estimate);
  final ClockEstimate estimate;
  @override
  String get type => 'clock';
  @override
  Map<String, Object?> fields() => {'estimate': estimate.toJson()};
}

/// Lock camera settings and get ready to record [recordingId].
class Prepare extends Msg {
  const Prepare(this.recordingId);
  final String recordingId;
  @override
  String get type => 'prepare';
  @override
  Map<String, Object?> fields() => {'recordingId': recordingId};
}

class Prepared extends Msg {
  const Prepared({required this.recordingId, this.video, this.error});
  final String recordingId;
  final VideoInfo? video;
  final String? error;
  bool get ok => error == null;
  @override
  String get type => 'prepared';
  @override
  Map<String, Object?> fields() => {
        'recordingId': recordingId,
        'video': video?.toJson(),
        'error': error,
      };
}

/// Start recording at Main-clock time [atMainMs].
class Start extends Msg {
  const Start({required this.recordingId, required this.atMainMs});
  final String recordingId;
  final int atMainMs;
  @override
  String get type => 'start';
  @override
  Map<String, Object?> fields() =>
      {'recordingId': recordingId, 'atMainMs': atMainMs};
}

class Started extends Msg {
  const Started({required this.recordingId, required this.startedAtDeviceMs});
  final String recordingId;
  final int startedAtDeviceMs;
  @override
  String get type => 'started';
  @override
  Map<String, Object?> fields() =>
      {'recordingId': recordingId, 'startedAtDeviceMs': startedAtDeviceMs};
}

class Stop extends Msg {
  const Stop(this.recordingId);
  final String recordingId;
  @override
  String get type => 'stop';
  @override
  Map<String, Object?> fields() => {'recordingId': recordingId};
}

/// Recording has stopped and [segmentCount] segments exist. Their
/// [SegmentMsg]s may still be on the way (hashing takes a few seconds).
class Stopped extends Msg {
  const Stopped({required this.recordingId, required this.segmentCount});
  final String recordingId;
  final int segmentCount;
  @override
  String get type => 'stopped';
  @override
  Map<String, Object?> fields() =>
      {'recordingId': recordingId, 'segmentCount': segmentCount};
}

/// One finished, hashed segment on Secondary. Sent as each segment
/// completes, and re-sent after a reconnect.
class SegmentMsg extends Msg {
  const SegmentMsg({required this.recordingId, required this.segment});
  final String recordingId;
  final SegmentRecord segment;
  @override
  String get type => 'segment';
  @override
  Map<String, Object?> fields() =>
      {'recordingId': recordingId, 'segment': segment.toJson()};
}

/// Secondary's periodic heartbeat.
class StatusMsg extends Msg {
  const StatusMsg({
    required this.batteryPercent,
    required this.charging,
    required this.freeStorageBytes,
    required this.thermalState,
    required this.recordingId,
    required this.segmentCount,
    required this.elapsedMs,
  });
  final int batteryPercent;
  final bool charging;
  final int freeStorageBytes;
  final String thermalState;

  /// Set while recording.
  final String? recordingId;
  final int segmentCount;
  final int elapsedMs;
  bool get recording => recordingId != null;
  @override
  String get type => 'status';
  @override
  Map<String, Object?> fields() => {
        'batteryPercent': batteryPercent,
        'charging': charging,
        'freeStorageBytes': freeStorageBytes,
        'thermalState': thermalState,
        'recordingId': recordingId,
        'segmentCount': segmentCount,
        'elapsedMs': elapsedMs,
      };
}

class ErrorMsg extends Msg {
  const ErrorMsg({required this.code, required this.message});
  final String code;
  final String message;
  @override
  String get type => 'error';
  @override
  Map<String, Object?> fields() => {'code': code, 'message': message};
}
