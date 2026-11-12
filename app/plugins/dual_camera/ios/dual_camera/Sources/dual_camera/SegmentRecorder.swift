// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// Splits one recording into gapless segment files.
///
/// Rotation happens at a video frame boundary: the first video frame whose
/// PTS reaches the nominal segment end starts the next writer's session at
/// exactly that PTS, and the previous writer's session ends at the same PTS.
/// Audio is routed by PTS: a buffer that straddles the boundary is split at
/// the boundary sample, so the two files' audio tracks abut exactly. Because
/// audio usually arrives a little after the matching video, the previous
/// writer stays open ("closing") until audio past its end has been seen.
///
/// Every method must be called on `queue` (the capture queue). The only
/// other queue is `prepQueue`, which builds the next writer ahead of time.
final class SegmentRecorder {
  struct Settings {
    let directory: URL
    let filePrefix: String
    let segmentDuration: CMTime
    let frameDuration: CMTime
    let videoSettings: [String: Any]
    let audioSettings: [String: Any]
    /// Display transform for the video track (see `SegmentWriter.uprightTransform`).
    let transform: CGAffineTransform
  }

  /// First frame written; argument is its wall-clock time in ms.
  var onStarted: ((Int64) -> Void)?
  /// A segment file is complete. Called in index order.
  var onSegment: ((SegmentInfo) -> Void)?
  /// (code, message, fatal). On fatal the owner must call `stop`.
  var onError: ((String, String, Bool) -> Void)?

  private let settings: Settings
  private let queue: DispatchQueue
  /// The capture clock that video timestamps are on. Asked for each time,
  /// because the session's clock can change when its inputs change.
  private let clock: () -> CMClock
  private let prepQueue = DispatchQueue(label: "dev.opensportsball.dual_camera.prepare")

  /// Writer 0, created eagerly, until the first video frame starts it.
  private var first: SegmentWriter?
  private var current: SegmentWriter?
  /// Writers whose end is fixed and which are waiting for trailing audio.
  private var closing: [SegmentWriter] = []
  private var nominalEnd: CMTime = .invalid
  private var lastVideoPTS: CMTime = .invalid
  private var nextIndex = 0
  private var pendingAudio: [CMSampleBuffer] = []

  private var stopping = false
  private var failed = false
  private var stopCompletions: [() -> Void] = []
  private var outstandingFinishes = 0
  /// Finished outcomes waiting to be reported in index order.
  private var outcomes: [Int: FinishOutcome] = [:]
  private var nextToReport = 0

  // Only touched on prepQueue.
  private var preparedSlot: Result<SegmentWriter, Error>?

  /// Audio this far past the nominal end, with no video frame to trigger
  /// rotation, is routed anyway (video has stalled).
  private static let maxPendingAudio = 200
  /// A closing writer is finished at the latest this long after its end,
  /// even if no audio has come past it.
  private static let closingTimeout = CMTime(seconds: 1, preferredTimescale: 600)

  init(settings: Settings, clock: @escaping () -> CMClock, queue: DispatchQueue) throws {
    self.settings = settings
    self.clock = clock
    self.queue = queue
    try FileManager.default.createDirectory(at: settings.directory, withIntermediateDirectories: true)
    first = try makeWriter(index: 0)
    nextIndex = 1
  }

  // MARK: - Input

  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    guard !stopping, !failed else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard pts.isValid else { return }

    if current == nil {
      // The first frame of the recording, or the first after `split`.
      let writer: SegmentWriter
      if let unused = first {
        first = nil
        writer = unused
      } else {
        do {
          writer = try takePrepared()
        } catch {
          fail("could not create segment \(nextIndex): \(error.localizedDescription)")
          return
        }
      }
      writer.startSession(at: pts, deviceMs: wallClockMs(pts))
      current = writer
      nominalEnd = CMTimeAdd(pts, settings.segmentDuration)
      prepareNext()
      let started = onStarted
      onStarted = nil
      started?(writer.startedAtDeviceMs)
    } else if CMTimeCompare(pts, nominalEnd) >= 0 {
      rotate(at: pts)
      if failed { return }
    }

    guard let writer = current else { return }
    if !writer.appendVideo(sampleBuffer) {
      fail("writing segment \(writer.index) failed: \(writer.errorDescription)")
      return
    }
    lastVideoPTS = pts

    // If audio has stopped arriving, don't hold old writers open forever.
    for old in closing where CMTimeCompare(CMTimeSubtract(pts, old.end), Self.closingTimeout) > 0 {
      finish(old)
    }
    drainAudio(force: false)
  }

  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    guard !failed else { return }
    if stopping && closing.isEmpty { return }
    pendingAudio.append(sampleBuffer)
    drainAudio(force: false)
  }

  // MARK: - Split

  /// Ends the current segment at the last frame written; the next video
  /// frame starts a new segment. For a break in capture (an interruption, or
  /// a change of inputs): the frames after it may be much later, or on
  /// another clock, so they get a file with its own start time instead of
  /// a hidden gap inside one file.
  func split() {
    guard !stopping, !failed, let writer = current else { return }
    current = nil
    writer.end = lastVideoPTS.isValid
      ? CMTimeAdd(lastVideoPTS, settings.frameDuration)
      : CMTimeAdd(writer.start, settings.frameDuration)
    closing.append(writer)
    // Capture has stopped, so no trailing audio is coming.
    drainAudio(force: true)
    for old in closing { finish(old) }
    pendingAudio.removeAll()
    nominalEnd = .invalid
    lastVideoPTS = .invalid
  }

  // MARK: - Stop

  /// Finalizes everything. `completion` runs on `queue` after every
  /// finished segment has been reported through `onSegment`.
  func stop(completion: @escaping () -> Void) {
    stopCompletions.append(completion)
    if stopping { return }
    stopping = true
    onStarted = nil
    discardPrepared()

    if let unused = first {
      // Recording never got a frame.
      first = nil
      unused.cancel()
      outcomes[unused.index] = .empty
    }
    if let writer = current {
      current = nil
      writer.end = lastVideoPTS.isValid
        ? CMTimeAdd(lastVideoPTS, settings.frameDuration)
        : CMTimeAdd(writer.start, settings.frameDuration)
      closing.append(writer)
    }
    if failed {
      for writer in closing { finish(writer) }
    } else {
      drainAudio(force: true)
      // Give trailing audio (which lags video slightly) a moment to arrive.
      queue.asyncAfter(deadline: .now() + 0.5) { [self] in
        for writer in closing { finish(writer) }
        pendingAudio.removeAll()
        checkStopDone()
      }
    }
    reportReady()
    checkStopDone()
  }

  // MARK: - Rotation

  private func rotate(at boundary: CMTime) {
    guard let old = current else { return }
    let next: SegmentWriter
    do {
      next = try takePrepared()
    } catch {
      fail("could not create segment \(nextIndex): \(error.localizedDescription)")
      return
    }
    old.end = boundary
    closing.append(old)
    next.startSession(at: boundary, deviceMs: wallClockMs(boundary))
    current = next
    nominalEnd = CMTimeAdd(boundary, settings.segmentDuration)
    prepareNext()
  }

  private func makeWriter(index: Int) throws -> SegmentWriter {
    let name = String(format: "%@_%03d.mp4", settings.filePrefix, index)
    return try SegmentWriter(
      index: index,
      url: settings.directory.appendingPathComponent(name),
      videoSettings: settings.videoSettings,
      audioSettings: settings.audioSettings,
      transform: settings.transform)
  }

  /// Builds the next writer on `prepQueue` so rotation doesn't stall capture.
  private func prepareNext() {
    let index = nextIndex
    nextIndex += 1
    prepQueue.async { [weak self] in
      guard let self else { return }
      let result = Result { try self.makeWriter(index: index) }
      if case .success(let stale)? = self.preparedSlot { stale.cancel() }
      self.preparedSlot = result
    }
  }

  /// Takes the prepared writer, waiting for it if it is still being built.
  private func takePrepared() throws -> SegmentWriter {
    let result: Result<SegmentWriter, Error>? = prepQueue.sync {
      let r = preparedSlot
      preparedSlot = nil
      return r
    }
    switch result {
    case .success(let writer)?:
      return writer
    case .failure(let error)?:
      throw error
    case nil:
      let writer = try makeWriter(index: nextIndex)
      nextIndex += 1
      return writer
    }
  }

  private func discardPrepared() {
    prepQueue.async { [weak self] in
      guard let self else { return }
      if case .success(let writer)? = self.preparedSlot { writer.cancel() }
      self.preparedSlot = nil
    }
  }

  // MARK: - Audio routing

  private func drainAudio(force: Bool) {
    while let buffer = pendingAudio.first {
      if current == nil && closing.isEmpty {
        // Before the first frame: keep only recent buffers, one of which
        // may straddle the first frame's PTS.
        if pendingAudio.count > 8 { pendingAudio.removeFirst(pendingAudio.count - 8) }
        return
      }
      let (a0, a1) = audioRange(buffer)
      if current != nil, !force, CMTimeCompare(a1, nominalEnd) > 0,
         pendingAudio.count < Self.maxPendingAudio {
        // Audio is ahead of video. Wait for the frame that decides the
        // exact boundary.
        return
      }
      pendingAudio.removeFirst()
      route(buffer, from: a0, to: a1)
      if failed { return }
    }
  }

  private func route(_ buffer: CMSampleBuffer, from a0: CMTime, to a1: CMTime) {
    var targets = closing
    if let writer = current { targets.append(writer) }
    for writer in targets {
      let lo = CMTimeMaximum(a0, writer.start)
      let hi = writer.end.isValid ? CMTimeMinimum(a1, writer.end) : a1
      guard CMTimeCompare(lo, hi) < 0 else { continue }
      let part: CMSampleBuffer?
      if CMTimeCompare(lo, a0) == 0 && CMTimeCompare(hi, a1) == 0 {
        part = buffer
      } else {
        part = sliceAudio(buffer, from: lo, to: hi)
      }
      if let part, !writer.appendAudio(part) {
        fail("writing audio to segment \(writer.index) failed: \(writer.errorDescription)")
        return
      }
    }
    // Writers whose end audio has now passed have everything they need.
    for writer in closing where CMTimeCompare(a1, writer.end) >= 0 {
      finish(writer)
    }
  }

  // MARK: - Finishing and reporting

  private func finish(_ writer: SegmentWriter) {
    guard let i = closing.firstIndex(where: { $0 === writer }) else { return }
    closing.remove(at: i)
    outstandingFinishes += 1
    writer.finish { [weak self] outcome in
      guard let self else { return }
      self.queue.async {
        self.outstandingFinishes -= 1
        self.outcomes[writer.index] = outcome
        self.reportReady()
        self.checkStopDone()
      }
    }
  }

  private func reportReady() {
    while let outcome = outcomes.removeValue(forKey: nextToReport) {
      nextToReport += 1
      switch outcome {
      case .finished(let info):
        onSegment?(info)
      case .empty:
        break
      case .failed(let message):
        onError?("io_error", message, false)
      }
    }
  }

  private func checkStopDone() {
    guard stopping, current == nil, closing.isEmpty, outstandingFinishes == 0 else { return }
    // Anything left in `outcomes` is out of order only because an earlier
    // index never produced an outcome; report it anyway.
    for index in outcomes.keys.sorted() where index >= nextToReport {
      nextToReport = index
      reportReady()
    }
    let completions = stopCompletions
    stopCompletions.removeAll()
    completions.forEach { $0() }
  }

  private func fail(_ message: String) {
    guard !failed else { return }
    failed = true
    onError?("io_error", message, true)
  }

  // MARK: - Helpers

  /// Converts a capture timestamp (session synchronization clock) to
  /// wall-clock ms: wall = nowWall - (nowClock - pts).
  private func wallClockMs(_ pts: CMTime) -> Int64 {
    let nowClock = CMClockGetTime(clock())
    let nowWall = Date().timeIntervalSince1970
    let age = CMTimeSubtract(nowClock, pts).seconds
    return Int64(((nowWall - age) * 1000).rounded())
  }

  private func audioRange(_ buffer: CMSampleBuffer) -> (CMTime, CMTime) {
    let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
    var duration = CMSampleBufferGetDuration(buffer)
    if !duration.isValid || duration.value == 0 {
      let samples = CMSampleBufferGetNumSamples(buffer)
      let rate = sampleRate(buffer)
      duration = CMTime(value: CMTimeValue(samples), timescale: CMTimeScale(rate > 0 ? rate : 48000))
    }
    return (pts, CMTimeAdd(pts, duration))
  }

  private func sampleRate(_ buffer: CMSampleBuffer) -> Double {
    guard let format = CMSampleBufferGetFormatDescription(buffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else { return 0 }
    return asbd.pointee.mSampleRate
  }

  /// The samples of `buffer` that fall in [lo, hi). Boundaries are rounded
  /// to whole samples the same way on both sides of a split, so no sample is
  /// duplicated or lost.
  private func sliceAudio(_ buffer: CMSampleBuffer, from lo: CMTime, to hi: CMTime) -> CMSampleBuffer? {
    let count = CMSampleBufferGetNumSamples(buffer)
    let rate = sampleRate(buffer)
    guard count > 0, rate > 0 else { return nil }
    let a0 = CMSampleBufferGetPresentationTimeStamp(buffer)
    func sampleIndex(_ t: CMTime) -> Int {
      let i = Int((CMTimeSubtract(t, a0).seconds * rate).rounded())
      return min(max(i, 0), count)
    }
    let i0 = sampleIndex(lo)
    let i1 = sampleIndex(hi)
    guard i1 > i0 else { return nil }
    var out: CMSampleBuffer?
    let status = CMSampleBufferCopySampleBufferForRange(
      allocator: kCFAllocatorDefault,
      sampleBuffer: buffer,
      sampleRange: CFRange(location: i0, length: i1 - i0),
      sampleBufferOut: &out)
    guard status == noErr else {
      NSLog("dual_camera: could not split audio buffer (%d)", status)
      return nil
    }
    return out
  }
}
