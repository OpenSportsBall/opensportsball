// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opensportsball/src/model.dart';
import 'package:opensportsball/src/protocol/clock_sync.dart';
import 'package:opensportsball/src/protocol/framing.dart';
import 'package:opensportsball/src/protocol/messages.dart';
import 'package:opensportsball/src/protocol/peer_auth.dart';
import 'package:opensportsball/src/ui/common.dart';

void main() {
  group('framing', () {
    Uint8List bytes(int n) => Uint8List.fromList(List.generate(n, (i) => i % 251));

    for (final size in [0, 1, 17, 20, 21, 500, 4000]) {
      test('round-trips $size bytes in 20-byte frames', () {
        final frames = FrameEncoder().encode(bytes(size), 20);
        expect(frames.every((f) => f.length <= 20), isTrue);
        final d = FrameDecoder();
        Uint8List? out;
        for (final f in frames) {
          out = d.add(f);
        }
        expect(out, bytes(size));
      });
    }

    test('returns null until the last frame', () {
      final frames = FrameEncoder().encode(bytes(100), 20);
      final d = FrameDecoder();
      for (final f in frames.take(frames.length - 1)) {
        expect(d.add(f), isNull);
      }
      expect(d.add(frames.last), bytes(100));
    });

    test('a lost frame drops only that message', () {
      final enc = FrameEncoder();
      final first = enc.encode(bytes(60), 20);
      final second = enc.encode(bytes(40), 20);
      final d = FrameDecoder();
      d.add(first[0]); // rest of `first` is lost
      Uint8List? out;
      for (final f in second) {
        out = d.add(f);
      }
      expect(out, bytes(40));
    });

    test('rejects messages over 255 frames', () {
      expect(() => FrameEncoder().encode(bytes(255 * 17 + 1), 20), throwsArgumentError);
    });

    test('ignores malformed frames', () {
      final d = FrameDecoder();
      expect(d.add(Uint8List.fromList([1])), isNull);
      expect(d.add(Uint8List.fromList([1, 5, 2, 9])), isNull); // index >= count
    });
  });

  group('clock sync', () {
    test('recovers a known offset despite asymmetric jitter', () {
      const trueOffset = 1234.0; // secondary - main
      final rng = Random(7);
      final samples = <ClockSample>[];
      var main = 1000000;
      for (var i = 0; i < 40; i++) {
        main += 150;
        final up = 8 + rng.nextInt(60); // ms, secondary -> main
        final down = 8 + rng.nextInt(60);
        final t2 = main;
        final t1 = (t2 - up + trueOffset).round();
        final t3 = (t2 + down + trueOffset).round();
        samples.add(ClockSample(t1: t1, t2: t2, t3: t3));
      }
      final est = estimateClock(samples)!;
      expect(est.secondaryOffsetMs, closeTo(trueOffset, 15));
      expect(est.samples, 40);
    });

    test('no samples gives no estimate', () {
      expect(estimateClock([]), isNull);
    });

    test('fewer than three samples (pongs lost) still give an estimate', () {
      final est = estimateClock(const [ClockSample(t1: 0, t2: 15, t3: 20), ClockSample(t1: 0, t2: 25, t3: 40)])!;
      expect(est.samples, 2);
      expect(est.secondaryOffsetMs, closeTo(-5, 0.01));
    });
  });

  test('every message type round-trips', () {
    const device = DeviceIdentity(deviceId: 'd1', platform: 'android', model: 'Pixel 9');
    const video = VideoInfo(
        width: 3840, height: 2160, nominalFps: 30, codec: 'hevc', lens: 'ultrawide',
        bitrateBps: 35000000, horizontalFovDeg: 108);
    const seg = SegmentRecord(
        index: 2, fileName: 'd1_002.mp4', bytes: 99, sha256: 'ab', startedAtDeviceMs: 5, durationMs: 300000);
    final msgs = <Msg>[
      const Hello(device),
      const Welcome(gameId: 'g', mainDeviceId: 'm', settings: RecordingSettings()),
      const Ping(id: 1, t1: 2),
      const Pong(id: 1, t1: 2, t2: 3),
      const ClockReport(ClockEstimate(secondaryOffsetMs: -3.5, medianRttMs: 40, samples: 20)),
      const Prepare('r'),
      const Prepared(recordingId: 'r', video: video),
      const Prepared(recordingId: 'r', error: 'no camera'),
      const Start(recordingId: 'r', atMainMs: 10),
      const Started(recordingId: 'r', startedAtDeviceMs: 11),
      const Stop('r'),
      const Stopped(recordingId: 'r', segmentCount: 3),
      const SegmentMsg(recordingId: 'r', segment: seg),
      const StatusMsg(
          batteryPercent: 50, charging: true, freeStorageBytes: 1, thermalState: 'fair',
          recordingId: null, segmentCount: 0, elapsedMs: 0),
      const ErrorMsg(code: 'c', message: 'm'),
      GrantMsg(RecordingGrant(
          apiUrl: 'https://api.test',
          token: 'osbg_x',
          accountId: 'acc-1',
          gameId: 'g',
          expiresAt: DateTime.utc(2026, 10, 25))),
      const GrantAck(gameId: 'g'),
      const GrantAck(gameId: 'g', error: 'nope'),
    ];
    for (final m in msgs) {
      final back = Msg.decode(m.encode());
      expect(back.runtimeType, m.runtimeType);
      expect(back.fields(), m.fields(), reason: m.type);
    }
  });

  group('pairing code', () {
    const game = '0f8fad5b-d9cb-469f-a165-70867728950e';
    final key = newPeerKey(Random(1));
    test('round-trips', () {
      final p = parsePairingUri(pairingUri(game, key))!;
      expect(p.gameId, game);
      expect(p.key, key);
    });
    test('rejects other codes', () {
      final k = pairingUri(game, key).split('&k=').last;
      expect(parsePairingUri('https://example.com'), isNull);
      expect(parsePairingUri('opensportsball://pair?v=1&game=$game'), isNull, reason: 'no key');
      expect(parsePairingUri('opensportsball://pair?v=2&game=$game'), isNull);
      expect(parsePairingUri('opensportsball://pair?v=2&game=$game&k=AAAA'), isNull, reason: 'short key');
      expect(parsePairingUri('opensportsball://pair?v=2&game=not-a-uuid&k=$k'), isNull);
    });
  });

  group('peer auth', () {
    final key = newPeerKey(Random(2));
    final msg = Uint8List.fromList(utf8.encode('{"type":"hello"}'));
    var now = DateTime.utc(2026, 11, 2, 12);
    DateTime clock() => now;

    test('opens what the other phone sealed', () {
      final sealed = PeerAuth(key, now: clock).seal(msg, PeerDirection.toMain);
      expect(PeerAuth(key, now: clock).open(sealed, PeerDirection.toMain), msg);
    });

    test('rejects another key, the other direction, and tampering', () {
      final sealed = PeerAuth(key, now: clock).seal(msg, PeerDirection.toMain);
      expect(PeerAuth(newPeerKey(Random(3)), now: clock).open(sealed, PeerDirection.toMain), isNull);
      expect(PeerAuth(key, now: clock).open(sealed, PeerDirection.toSecondary), isNull);
      final bad = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
      expect(PeerAuth(key, now: clock).open(bad, PeerDirection.toMain), isNull);
      expect(PeerAuth(key, now: clock).open(Uint8List(10), PeerDirection.toMain), isNull);
    });

    test('rejects replays and stale messages', () {
      final sender = PeerAuth(key, now: clock), receiver = PeerAuth(key, now: clock);
      final first = sender.seal(msg, PeerDirection.toMain);
      final second = sender.seal(msg, PeerDirection.toMain);
      expect(receiver.open(second, PeerDirection.toMain), msg);
      expect(receiver.open(second, PeerDirection.toMain), isNull, reason: 'replayed');
      expect(receiver.open(first, PeerDirection.toMain), isNull, reason: 'older than the last');

      final old = sender.seal(msg, PeerDirection.toMain);
      now = now.add(kPeerAuthWindow + const Duration(seconds: 1));
      expect(PeerAuth(key, now: clock).open(old, PeerDirection.toMain), isNull, reason: 'too old');
    });
  });
}
