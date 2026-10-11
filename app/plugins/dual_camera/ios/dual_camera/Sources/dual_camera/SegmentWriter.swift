// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// One finished segment file, as reported in the `segment` event.
struct SegmentInfo {
  let index: Int
  let path: String
  let bytes: Int64
  let startedAtDeviceMs: Int64
  let durationMs: Int64

  var event: [String: Any] {
    [
      "type": "segment",
      "index": index,
      "path": path,
      "bytes": bytes,
      "startedAtDeviceMs": startedAtDeviceMs,
      "durationMs": durationMs,
    ]
  }
}

enum FinishOutcome {
  case finished(SegmentInfo)
  /// Nothing was ever appended; the file was deleted.
  case empty
  case failed(String)
}

/// Wraps one AVAssetWriter writing one segment file.
///
/// The writer is created and `startWriting()` is called in `init`, which is
/// the expensive part (file creation, encoder setup), so the recorder can
/// build the next segment's writer ahead of time on another queue. After
/// hand-off, every method is called on the capture queue only.
final class SegmentWriter {
  let index: Int
  let url: URL

  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let audioInput: AVAssetWriterInput

  /// Source time of the first video frame (session start). Invalid until
  /// `startSession`.
  private(set) var start: CMTime = .invalid
  /// Exclusive end of this segment: the PTS of the next segment's first
  /// frame, or last frame + one frame duration for the final segment.
  /// Invalid while this is the current segment.
  var end: CMTime = .invalid
  private(set) var startedAtDeviceMs: Int64 = 0
  private(set) var videoFrames = 0
  private(set) var droppedVideo = 0
  private(set) var droppedAudio = 0
  private var finished = false

  init(index: Int, url: URL, videoSettings: [String: Any], audioSettings: [String: Any]) throws {
    self.index = index
    self.url = url
    // AVAssetWriter refuses to overwrite an existing file.
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    // Crash resilience: fragments are flushed every ~10 s, so a crash or
    // power loss leaves a playable partial file.
    writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
    writer.shouldOptimizeForNetworkUse = false

    guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
      throw CameraError("unsupported_config", "video settings not supported by AVAssetWriter: \(videoSettings)")
    }
    guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
      throw CameraError("unsupported_config", "audio settings not supported by AVAssetWriter: \(audioSettings)")
    }
    videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = true
    audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    audioInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
      throw CameraError("internal", "cannot add inputs to AVAssetWriter")
    }
    writer.add(videoInput)
    writer.add(audioInput)
    guard writer.startWriting() else {
      let message = writer.error?.localizedDescription ?? "unknown error"
      try? FileManager.default.removeItem(at: url)
      throw CameraError("io_error", "could not start writing \(url.lastPathComponent): \(message)")
    }
  }

  var hasFailed: Bool { writer.status == .failed }
  var errorDescription: String { writer.error?.localizedDescription ?? "unknown writer error" }

  func startSession(at pts: CMTime, deviceMs: Int64) {
    writer.startSession(atSourceTime: pts)
    start = pts
    startedAtDeviceMs = deviceMs
  }

  /// Returns false only if the writer has failed. A sample dropped because
  /// the encoder is momentarily busy is counted, not treated as a failure.
  @discardableResult
  func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard writer.status == .writing else { return false }
    if videoInput.isReadyForMoreMediaData {
      if !videoInput.append(sampleBuffer) { return writer.status != .failed }
      videoFrames += 1
    } else {
      droppedVideo += 1
    }
    return true
  }

  @discardableResult
  func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard writer.status == .writing else { return false }
    if audioInput.isReadyForMoreMediaData {
      if !audioInput.append(sampleBuffer) { return writer.status != .failed }
    } else {
      droppedAudio += 1
    }
    return true
  }

  /// Finishes the file. `completion` runs on an arbitrary queue.
  func finish(completion: @escaping (FinishOutcome) -> Void) {
    guard !finished else { return }
    finished = true
    guard writer.status == .writing else {
      let message = errorDescription
      cancel()
      completion(.failed("segment \(index) could not be finished: \(message)"))
      return
    }
    guard videoFrames > 0, start.isValid else {
      cancel()
      completion(.empty)
      return
    }
    videoInput.markAsFinished()
    audioInput.markAsFinished()
    if end.isValid {
      writer.endSession(atSourceTime: end)
    }
    if droppedVideo > 0 || droppedAudio > 0 {
      NSLog("dual_camera: segment %d dropped %d video and %d audio samples (encoder busy)",
            index, droppedVideo, droppedAudio)
    }
    let startTime = start
    let endTime = end
    let deviceMs = startedAtDeviceMs
    // The closure keeps `self` (and so the writer) alive until done.
    writer.finishWriting { [self] in
      guard writer.status == .completed else {
        completion(.failed("segment \(index) failed to finalize: \(errorDescription)"))
        return
      }
      let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
      let durationMs: Int64
      if endTime.isValid {
        durationMs = Int64((CMTimeSubtract(endTime, startTime).seconds * 1000).rounded())
      } else {
        durationMs = 0
      }
      completion(.finished(SegmentInfo(
        index: index,
        path: url.path,
        bytes: Int64(bytes),
        startedAtDeviceMs: deviceMs,
        durationMs: durationMs)))
    }
  }

  /// Abandons the file (used for a prepared writer that is never needed).
  func cancel() {
    finished = true
    if writer.status == .writing || writer.status == .unknown {
      writer.cancelWriting()
    }
    try? FileManager.default.removeItem(at: url)
  }
}
