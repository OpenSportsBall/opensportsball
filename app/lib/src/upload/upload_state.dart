// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/// Upload progress for one recording, saved as `upload.json` next to
/// `recording.json`:
///
/// ```json
/// {
///   "version": 1,
///   "accountId": "acc-1",
///   "manifest": {"sha256": "<hex of the uploaded manifest.json>", "status": "uploading"},
///   "segments": {
///     "<deviceId>_000.mp4": {"done": true},
///     "<deviceId>_001.mp4": {
///       "done": false,
///       "uploadId": "...",
///       "partSizeBytes": 67108864,
///       "parts": {"1": "\"etag-1\"", "2": "\"etag-2\""}
///     }
///   },
///   "lastError": null
/// }
/// ```
///
/// State recorded under a different account (the phone was re-linked) is
/// ignored, so everything uploads again to the new account.
library;

class UploadState {
  UploadState({
    this.accountId,
    this.manifestSha256,
    this.manifestStatus,
    Map<String, SegmentUpload>? segments,
    this.lastError,
  }) : segments = segments ?? {};

  factory UploadState.fromJson(Map<String, Object?> j) {
    final manifest = (j['manifest'] as Map?)?.cast<String, Object?>();
    return UploadState(
      accountId: j['accountId'] as String?,
      manifestSha256: manifest?['sha256'] as String?,
      manifestStatus: manifest?['status'] as String?,
      segments: {
        for (final e in ((j['segments'] as Map?) ?? const {}).entries)
          e.key as String: SegmentUpload.fromJson((e.value as Map).cast()),
      },
      lastError: j['lastError'] as String?,
    );
  }

  String? accountId;

  /// SHA-256 of the manifest.json content the server accepted; null if not
  /// uploaded. A changed manifest (different hash) is uploaded again.
  String? manifestSha256;
  String? manifestStatus;
  final Map<String, SegmentUpload> segments;
  String? lastError;

  SegmentUpload segment(String fileName) => segments.putIfAbsent(fileName, SegmentUpload.new);

  bool segmentDone(String fileName) => segments[fileName]?.done ?? false;

  Map<String, Object?> toJson() => {
        'version': 1,
        'accountId': accountId,
        'manifest': manifestSha256 == null
            ? null
            : {'sha256': manifestSha256, 'status': manifestStatus},
        'segments': {for (final e in segments.entries) e.key: e.value.toJson()},
        'lastError': lastError,
      };
}

/// One segment file's multipart upload.
class SegmentUpload {
  SegmentUpload({this.done = false, this.uploadId, this.partSizeBytes, Map<int, String>? parts})
      : parts = parts ?? {};

  factory SegmentUpload.fromJson(Map<String, Object?> j) => SegmentUpload(
        done: j['done'] as bool? ?? false,
        uploadId: j['uploadId'] as String?,
        partSizeBytes: j['partSizeBytes'] as int?,
        parts: {
          for (final e in ((j['parts'] as Map?) ?? const {}).entries)
            int.parse(e.key as String): e.value as String,
        },
      );

  bool done;
  String? uploadId;
  int? partSizeBytes;

  /// Part number → ETag (quotes included), for parts S3 has accepted.
  final Map<int, String> parts;

  /// Bytes already in S3 for a file of [fileBytes] bytes.
  int bytesUploaded(int fileBytes) {
    if (done) return fileBytes;
    final size = partSizeBytes;
    if (size == null) return 0;
    var sum = 0;
    for (final n in parts.keys) {
      final start = (n - 1) * size;
      final end = n * size < fileBytes ? n * size : fileBytes;
      if (end > start) sum += end - start;
    }
    return sum;
  }

  Map<String, Object?> toJson() => {
        'done': done,
        if (!done && uploadId != null) 'uploadId': uploadId,
        if (!done && partSizeBytes != null) 'partSizeBytes': partSizeBytes,
        if (!done && parts.isNotEmpty) 'parts': {for (final e in parts.entries) '${e.key}': e.value},
      };
}
