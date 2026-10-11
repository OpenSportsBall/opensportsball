// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Splits messages into frames that fit one BLE write or notification, and
/// reassembles them.
///
/// Frame layout: `[seq, index, count, ...payload]`. `seq` identifies the
/// message (wraps at 256), `index` is this frame's position and `count` the
/// number of frames. A message can be at most 255 frames.
library;

import 'dart:typed_data';

const kFrameHeaderBytes = 3;

class FrameEncoder {
  int _seq = 0;

  /// Splits [payload] into frames of at most [maxFrameBytes] bytes.
  List<Uint8List> encode(Uint8List payload, int maxFrameBytes) {
    final chunk = maxFrameBytes - kFrameHeaderBytes;
    if (chunk < 1) {
      throw ArgumentError.value(maxFrameBytes, 'maxFrameBytes', 'too small');
    }
    final count = payload.isEmpty ? 1 : (payload.length + chunk - 1) ~/ chunk;
    if (count > 255) {
      throw ArgumentError('message of ${payload.length} bytes needs $count '
          'frames; the limit is 255');
    }
    final seq = _seq;
    _seq = (_seq + 1) & 0xff;
    return [
      for (var i = 0; i < count; i++)
        Uint8List.fromList([
          seq,
          i,
          count,
          ...payload.sublist(
            i * chunk,
            (i + 1) * chunk > payload.length ? payload.length : (i + 1) * chunk,
          ),
        ]),
    ];
  }
}

class FrameDecoder {
  final _partial = <int, _Partial>{};

  /// Adds one frame. Returns the full payload once its last frame arrives,
  /// otherwise null. Malformed frames are dropped.
  Uint8List? add(Uint8List frame) {
    if (frame.length < kFrameHeaderBytes) return null;
    final seq = frame[0], index = frame[1], count = frame[2];
    if (count == 0 || index >= count) return null;
    final body = frame.sublist(kFrameHeaderBytes);
    if (count == 1) {
      _partial.remove(seq);
      return body;
    }

    var p = _partial[seq];
    // A first frame for a seq we were assembling means the sender wrapped
    // around or the old message was lost: start over.
    if (p == null || index == 0 || p.count != count) {
      p = _Partial(count);
      _partial[seq] = p;
    }
    p.chunks[index] = body;
    if (p.chunks.length < count) {
      if (_partial.length > 16) _partial.remove(_partial.keys.first);
      return null;
    }
    _partial.remove(seq);
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < count; i++) {
      final c = p.chunks[i];
      if (c == null) return null;
      out.add(c);
    }
    return out.toBytes();
  }
}

class _Partial {
  _Partial(this.count);
  final int count;
  final chunks = <int, Uint8List>{};
}
