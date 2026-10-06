// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import UIKit

/// One opened camera: the capture session, its device and outputs, and the
/// recorder while recording.
///
/// All capture, device and writer state lives on `queue`, which is also the
/// sample buffer delegate queue for both video and audio. Public methods
/// that touch that state must be called on `queue`, except the few marked
/// as thread-safe. Events are passed to `emit` (on `queue`); the plugin
/// forwards them to Flutter on the main thread.
final class CameraSession: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate
{
  let queue = DispatchQueue(label: "dev.sportsballvideo.dual_camera.capture", qos: .userInitiated)

  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()
  private let preview: PreviewTexture
  private let emit: ([String: Any]) -> Void

  private var device: AVCaptureDevice?
  private var config: OpenConfig?
  private var recordWidth = 0
  private var recordHeight = 0
  private var actualFps = 30
  private var codecType: AVVideoCodecType = .hevc

  private var recorder: SegmentRecorder?
  private var pendingStart: ((Result<Int64, CameraError>) -> Void)?
  private var storageTimer: DispatchSourceTimer?
  private var observers: [NSObjectProtocol] = []
  private var closed = false

  // Read from the main thread by `status`; guarded by `stateLock`.
  private let stateLock = NSLock()
  private var _recording = false
  private var _recordingDirectory: URL?

  init(preview: PreviewTexture, emit: @escaping ([String: Any]) -> Void) {
    self.preview = preview
    self.emit = emit
    super.init()
  }

  /// Thread-safe.
  var isRecording: Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    return _recording
  }

  /// Thread-safe.
  var recordingDirectory: URL? {
    stateLock.lock(); defer { stateLock.unlock() }
    return _recordingDirectory
  }

  private func setRecording(_ on: Bool, directory: URL?) {
    stateLock.lock()
    _recording = on
    _recordingDirectory = directory ?? _recordingDirectory
    stateLock.unlock()
  }

  // MARK: - Open

  /// Configures and starts the session. Call on `queue`.
  func open(_ cfg: OpenConfig, orientation: UIInterfaceOrientation) throws -> [String: Any] {
    config = cfg
    // We configure AVAudioSession ourselves; configureAudioSession turns
    // this back on if that fails.
    session.automaticallyConfiguresApplicationAudioSession = false
    configureAudioSession()

    let (camera, lensName) = try Self.selectDevice(lens: cfg.lens)
    device = camera

    session.beginConfiguration()
    var committed = false
    defer { if !committed { session.commitConfiguration() } }

    let videoInput: AVCaptureDeviceInput
    do {
      videoInput = try AVCaptureDeviceInput(device: camera)
    } catch {
      throw CameraError("camera_unavailable", "could not open camera: \(error.localizedDescription)")
    }
    guard session.canAddInput(videoInput) else {
      throw CameraError("camera_unavailable", "cannot add camera input")
    }
    session.addInput(videoInput)

    guard let mic = AVCaptureDevice.default(for: .audio) else {
      throw CameraError("camera_unavailable", "no microphone")
    }
    let audioInput: AVCaptureDeviceInput
    do {
      audioInput = try AVCaptureDeviceInput(device: mic)
    } catch {
      throw CameraError("camera_unavailable", "could not open microphone: \(error.localizedDescription)")
    }
    guard session.canAddInput(audioInput) else {
      throw CameraError("camera_unavailable", "cannot add microphone input")
    }
    session.addInput(audioInput)

    // Recording must not drop frames; a late frame is queued, not discarded.
    videoOutput.alwaysDiscardsLateVideoFrames = false
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(videoOutput) else {
      throw CameraError("camera_unavailable", "cannot add video output")
    }
    session.addOutput(videoOutput)
    audioOutput.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(audioOutput) else {
      throw CameraError("camera_unavailable", "cannot add audio output")
    }
    session.addOutput(audioOutput)

    // Format and frame rate. Setting activeFormat switches the session
    // preset to .inputPriority.
    guard let choice = Self.chooseFormat(camera, width: cfg.width, height: cfg.height, fps: cfg.fps) else {
      throw CameraError("unsupported_config", "camera has no usable 8-bit 4:2:0 video format")
    }
    actualFps = choice.fps
    do {
      try camera.lockForConfiguration()
      camera.activeFormat = choice.format
      let frameDuration = CMTime(value: 1, timescale: CMTimeScale(choice.fps))
      camera.activeVideoMinFrameDuration = frameDuration
      camera.activeVideoMaxFrameDuration = frameDuration
      if choice.format.isVideoHDRSupported {
        camera.automaticallyAdjustsVideoHDREnabled = false
        camera.isVideoHDREnabled = false
      }
      if camera.isLowLightBoostSupported {
        camera.automaticallyEnablesLowLightBoostWhenAvailable = false
      }
      camera.unlockForConfiguration()
    } catch {
      throw CameraError("camera_unavailable", "could not configure camera: \(error.localizedDescription)")
    }
    let subtype = CMFormatDescriptionGetMediaSubType(choice.format.formatDescription)
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: subtype]

    guard let connection = videoOutput.connection(with: .video) else {
      throw CameraError("internal", "video output has no connection")
    }
    if connection.isVideoStabilizationSupported {
      connection.preferredVideoStabilizationMode = .off
    }
    let quarterTurn = Self.applyRotation(connection, orientation: orientation)

    session.commitConfiguration()
    committed = true

    let dims = CMVideoFormatDescriptionGetDimensions(choice.format.formatDescription)
    recordWidth = Int(quarterTurn ? dims.height : dims.width)
    recordHeight = Int(quarterTurn ? dims.width : dims.height)

    codecType = try chooseCodec(requested: cfg.codec)

    observe()
    session.startRunning()
    guard session.isRunning else {
      throw CameraError("camera_unavailable", "capture session did not start (camera in use or interrupted)")
    }

    var result: [String: Any] = [
      "previewWidth": recordWidth,
      "previewHeight": recordHeight,
      "width": recordWidth,
      "height": recordHeight,
      "fps": actualFps,
      "codec": codecType == .hevc ? "hevc" : "h264",
      "lens": lensName,
    ]
    let fov = Double(choice.format.videoFieldOfView)
    if fov > 0 {
      // videoFieldOfView is horizontal for the sensor's landscape frame.
      result["horizontalFovDeg"] = quarterTurn ? Self.otherAxisFov(fov, dims) : fov
    }
    return result
  }

  static func availableLenses() -> [String] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
      mediaType: .video,
      position: .back)
    var lenses: [String] = []
    if discovery.devices.contains(where: { $0.deviceType == .builtInUltraWideCamera }) {
      lenses.append("ultrawide")
    }
    if discovery.devices.contains(where: { $0.deviceType == .builtInWideAngleCamera }) {
      lenses.append("wide")
    }
    return lenses
  }

  private static func selectDevice(lens: String) throws -> (AVCaptureDevice, String) {
    if lens == "ultrawide",
       let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
      return (ultra, "ultrawide")
    }
    if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
      return (wide, "wide")
    }
    throw CameraError("camera_unavailable", "no back camera")
  }

  private struct FormatChoice {
    let format: AVCaptureDevice.Format
    let fps: Int
  }

  /// Picks the 8-bit 4:2:0 format closest to the requested size that
  /// supports the requested frame rate (or the closest rate it can do).
  private static func chooseFormat(_ device: AVCaptureDevice, width: Int, height: Int, fps: Int) -> FormatChoice? {
    let videoRange = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let fullRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let wantLong = max(width, height)
    let wantShort = min(width, height)
    let wantAspect = Double(wantLong) / Double(wantShort)

    typealias Scored = (choice: FormatChoice, key: [Double])
    var best: Scored?
    for format in device.formats {
      let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
      guard subtype == videoRange || subtype == fullRange else { continue }
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let long = Int(max(dims.width, dims.height))
      let short = Int(min(dims.width, dims.height))
      guard short > 0 else { continue }
      let ranges = format.videoSupportedFrameRateRanges
      let supports = ranges.contains { Double(fps) >= $0.minFrameRate - 0.01 && Double(fps) <= $0.maxFrameRate + 0.01 }
      let maxRate = ranges.map(\.maxFrameRate).max() ?? 0
      let minRate = ranges.map(\.minFrameRate).min() ?? 0
      let actual = supports ? fps : Int(min(max(Double(fps), minRate), maxRate).rounded(.down))
      guard actual > 0 else { continue }
      let aspectOff = abs(Double(long) / Double(short) - wantAspect) > 0.01
      // Lower is better, compared lexicographically.
      let key: [Double] = [
        supports ? 0 : 1,
        aspectOff ? 1 : 0,
        Double(abs(long * short - wantLong * wantShort)),
        long >= wantLong ? 0 : 1,
        format.isVideoBinned ? 1 : 0,
        subtype == videoRange ? 0 : 1,
        Double(abs(actual - fps)),
      ]
      if best == nil || key.lexicographicallyPrecedes(best!.key) {
        best = (FormatChoice(format: format, fps: actual), key)
      }
    }
    return best?.choice
  }

  /// Rotates frames so they are upright for the given interface
  /// orientation. Returns true for a quarter turn (width/height swapped).
  private static func applyRotation(_ connection: AVCaptureConnection, orientation: UIInterfaceOrientation) -> Bool {
    // The back camera's native frame is upright in landscapeRight
    // (UIInterfaceOrientation and AVCaptureVideoOrientation names agree for
    // interface orientation).
    let angle: CGFloat
    let legacy: AVCaptureVideoOrientation
    switch orientation {
    case .landscapeLeft: angle = 180; legacy = .landscapeLeft
    case .portrait: angle = 90; legacy = .portrait
    case .portraitUpsideDown: angle = 270; legacy = .portraitUpsideDown
    default: angle = 0; legacy = .landscapeRight
    }
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
      } else {
        NSLog("dual_camera: rotation %.0f not supported", angle)
        return false
      }
    } else {
      if connection.isVideoOrientationSupported {
        connection.videoOrientation = legacy
      } else {
        return false
      }
    }
    return angle == 90 || angle == 270
  }

  private static func otherAxisFov(_ horizontalDeg: Double, _ dims: CMVideoDimensions) -> Double {
    // Pinhole approximation for the short axis.
    let h = Double(dims.height), w = Double(dims.width)
    let half = horizontalDeg * .pi / 360
    return 2 * atan(tan(half) * h / w) * 180 / .pi
  }

  private func chooseCodec(requested: String) throws -> AVVideoCodecType {
    let available = videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mp4)
    var candidates: [AVVideoCodecType] = []
    if requested == "hevc" && available.contains(.hevc) { candidates.append(.hevc) }
    candidates.append(.h264)
    // Check the settings with a throwaway writer (no file is created until
    // startWriting).
    let probeURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("dual_camera_probe_\(UUID().uuidString).mp4")
    guard let probe = try? AVAssetWriter(outputURL: probeURL, fileType: .mp4) else {
      return candidates[0]
    }
    for codec in candidates where probe.canApply(outputSettings: videoSettings(codec), forMediaType: .video) {
      return codec
    }
    throw CameraError("unsupported_config", "neither HEVC nor H.264 at \(recordWidth)x\(recordHeight) \(actualFps) fps is supported")
  }

  private func videoSettings(_ codec: AVVideoCodecType) -> [String: Any] {
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: config?.bitrateBps ?? 35_000_000,
      AVVideoExpectedSourceFrameRateKey: actualFps,
      AVVideoMaxKeyFrameIntervalKey: actualFps,
    ]
    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    return [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: recordWidth,
      AVVideoHeightKey: recordHeight,
      AVVideoCompressionPropertiesKey: compression,
    ]
  }

  private var audioSettings: [String: Any] {
    [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 128_000,
    ]
  }

  private func configureAudioSession() {
    let audio = AVAudioSession.sharedInstance()
    do {
      try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
      try audio.setPreferredSampleRate(48_000)
      try audio.setActive(true)
    } catch {
      NSLog("dual_camera: AVAudioSession setup failed (%@); letting the capture session configure it",
            error.localizedDescription)
      session.automaticallyConfiguresApplicationAudioSession = true
      return
    }
  }

  // MARK: - Lock settings

  /// Lets continuous AE/AWB/AF converge, then locks. Call on `queue`;
  /// `completion` runs on `queue`.
  func lockSettings(completion: @escaping (Result<[String: Bool], CameraError>) -> Void) {
    guard let camera = device, let cfg = config else {
      completion(.failure(CameraError("not_open", "camera is not open")))
      return
    }
    do {
      try camera.lockForConfiguration()
      if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
      if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
      if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
        camera.whiteBalanceMode = .continuousAutoWhiteBalance
      }
      camera.unlockForConfiguration()
    } catch {
      completion(.failure(CameraError("camera_unavailable", "could not configure camera: \(error.localizedDescription)")))
      return
    }
    // Give the 3A loops a second, then wait (up to 3 s more) for them to
    // report they have settled.
    queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.waitForConvergence(camera, cfg: cfg, attempt: 0, completion: completion)
    }
  }

  private func waitForConvergence(_ camera: AVCaptureDevice, cfg: OpenConfig, attempt: Int,
                                  completion: @escaping (Result<[String: Bool], CameraError>) -> Void) {
    let adjusting = camera.isAdjustingFocus || camera.isAdjustingExposure || camera.isAdjustingWhiteBalance
    if adjusting && attempt < 30 && !closed {
      queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.waitForConvergence(camera, cfg: cfg, attempt: attempt + 1, completion: completion)
      }
      return
    }
    guard !closed else {
      completion(.failure(CameraError("not_open", "camera was closed")))
      return
    }
    do {
      try camera.lockForConfiguration()
    } catch {
      completion(.failure(CameraError("camera_unavailable", "could not configure camera: \(error.localizedDescription)")))
      return
    }
    var whiteBalanceLocked = false
    if camera.isWhiteBalanceModeSupported(.locked) {
      camera.whiteBalanceMode = .locked
      whiteBalanceLocked = true
    }
    var focusLocked = false
    if camera.isLockingFocusWithCustomLensPositionSupported {
      // 1.0 is the farthest focus position.
      camera.setFocusModeLocked(lensPosition: 1.0, completionHandler: nil)
      focusLocked = true
    } else if camera.isFocusModeSupported(.locked) {
      camera.focusMode = .locked
      focusLocked = true
    } else if !camera.isFocusModeSupported(.autoFocus) && !camera.isFocusModeSupported(.continuousAutoFocus) {
      // Fixed-focus lens: focus can't move, so it is effectively locked.
      focusLocked = true
    }
    var exposureLocked = false
    if cfg.lockExposure && camera.isExposureModeSupported(.locked) {
      camera.exposureMode = .locked
      exposureLocked = true
    }
    camera.unlockForConfiguration()
    completion(.success([
      "exposureLocked": exposureLocked,
      "whiteBalanceLocked": whiteBalanceLocked,
      "focusLocked": focusLocked,
    ]))
  }

  // MARK: - Recording

  /// Call on `queue`; `completion` runs on `queue` once the first frame is
  /// written (or recording failed to start).
  func startRecording(directory: URL, filePrefix: String,
                      completion: @escaping (Result<Int64, CameraError>) -> Void) {
    guard !closed, let cfg = config else {
      completion(.failure(CameraError("not_open", "camera is not open")))
      return
    }
    guard recorder == nil else {
      completion(.failure(CameraError("already_recording", "already recording")))
      return
    }
    guard session.isRunning else {
      completion(.failure(CameraError("camera_unavailable", "capture session is not running (interrupted?)")))
      return
    }
    if DeviceInfo.freeStorageBytes(at: directory) < DeviceInfo.lowStorageBytes {
      completion(.failure(CameraError("io_error", "less than 500 MB of free storage")))
      return
    }
    let settings = SegmentRecorder.Settings(
      directory: directory,
      filePrefix: filePrefix,
      segmentDuration: CMTime(value: CMTimeValue(cfg.segmentDurationMs), timescale: 1000),
      frameDuration: CMTime(value: 1, timescale: CMTimeScale(actualFps)),
      videoSettings: videoSettings(codecType),
      audioSettings: audioSettings)
    let newRecorder: SegmentRecorder
    do {
      newRecorder = try SegmentRecorder(settings: settings, clock: captureClock, queue: queue)
    } catch let error as CameraError {
      completion(.failure(error))
      return
    } catch {
      completion(.failure(CameraError("io_error", "could not create recording: \(error.localizedDescription)")))
      return
    }
    newRecorder.onSegment = { [weak self] info in self?.emit(info.event) }
    newRecorder.onError = { [weak self] code, message, fatal in
      guard let self else { return }
      let event: [String: Any] = ["type": "error", "code": code, "message": message, "fatal": fatal]
      if fatal {
        self.endRecording(then: event, completion: nil)
      } else {
        self.emit(event)
      }
    }
    newRecorder.onStarted = { [weak self] ms in
      guard let self, let pending = self.pendingStart else { return }
      self.pendingStart = nil
      pending(.success(ms))
    }
    pendingStart = completion
    recorder = newRecorder
    setRecording(true, directory: directory)
    startStorageMonitor(directory)

    // If no frame arrives (session silently stalled), fail the call.
    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self, let pending = self.pendingStart, self.recorder === newRecorder else { return }
      self.pendingStart = nil
      self.endRecording(then: nil) {
        pending(.failure(CameraError("camera_unavailable", "no video frames arrived within 5 s")))
      }
    }
  }

  /// Call on `queue`. `completion` runs on `queue` after the last segment
  /// event has been emitted.
  func stopRecording(completion: @escaping (CameraError?) -> Void) {
    guard recorder != nil else {
      completion(CameraError("not_recording", "not recording"))
      return
    }
    endRecording(then: nil) { completion(nil) }
  }

  /// Stops and finalizes the recording (if any), then emits `event` (if
  /// any), then calls `completion`. Call on `queue`.
  private func endRecording(then event: [String: Any]?, completion: (() -> Void)?) {
    guard let active = recorder else {
      if let event { emit(event) }
      completion?()
      return
    }
    if let pending = pendingStart {
      pendingStart = nil
      pending(.failure(CameraError("camera_unavailable", "recording stopped before the first frame")))
    }
    active.stop { [weak self] in
      guard let self else { return }
      if self.recorder === active {
        self.recorder = nil
        self.stopStorageMonitor()
        self.setRecording(false, directory: nil)
      }
      if let event { self.emit(event) }
      completion?()
    }
  }

  private var captureClock: CMClock {
    if #available(iOS 15.4, *), let clock = session.synchronizationClock {
      return clock
    }
    return CMClockGetHostTimeClock()
  }

  private func startStorageMonitor(_ directory: URL) {
    stopStorageMonitor()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 5, repeating: 5)
    timer.setEventHandler { [weak self] in
      guard let self, self.recorder != nil else { return }
      let free = DeviceInfo.freeStorageBytes(at: directory)
      if free < DeviceInfo.lowStorageBytes {
        self.stopStorageMonitor()
        self.endRecording(then: [
          "type": "error",
          "code": "io_error",
          "message": "storage low (\(free / 1_000_000) MB free); recording stopped",
          "fatal": true,
        ], completion: nil)
      }
    }
    timer.resume()
    storageTimer = timer
  }

  private func stopStorageMonitor() {
    storageTimer?.cancel()
    storageTimer = nil
  }

  // MARK: - Close

  /// Stops recording (finalizing), stops the session. Call on `queue`;
  /// `completion` runs on `queue`.
  func close(completion: @escaping () -> Void) {
    endRecording(then: nil) { [weak self] in
      guard let self else { completion(); return }
      self.closed = true
      for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
      self.observers.removeAll()
      if self.session.isRunning { self.session.stopRunning() }
      self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
      self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
      self.preview.clear()
      completion()
    }
  }

  // MARK: - Interruptions

  private func observe() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
    ) { [weak self] note in
      let reason = DeviceInfo.interruptionReason(note)
      self?.queue.async { self?.handleInterruption(reason) }
    })
    observers.append(center.addObserver(
      forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
    ) { [weak self] note in
      let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
      self?.queue.async { self?.handleRuntimeError(error) }
    })
  }

  private func handleInterruption(_ reason: String) {
    guard !closed else { return }
    endRecording(then: ["type": "interrupted", "reason": reason], completion: nil)
  }

  private func handleRuntimeError(_ error: AVError?) {
    guard !closed else { return }
    let message = error?.localizedDescription ?? "unknown"
    endRecording(then: ["type": "interrupted", "reason": "runtime_error: \(message)"]) { [weak self] in
      // After a media services reset the session can be restarted; the
      // preview resumes and the app can start a new recording.
      guard let self, !self.closed, error?.code == .mediaServicesWereReset else { return }
      self.session.startRunning()
    }
  }

  // MARK: - Sample buffers (on `queue`)

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    if output === videoOutput {
      if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
        preview.update(pixelBuffer)
      }
      recorder?.appendVideo(sampleBuffer)
    } else if output === audioOutput {
      recorder?.appendAudio(sampleBuffer)
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard output === videoOutput, recorder != nil else { return }
    var mode: CMAttachmentMode = 0
    let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                 attachmentModeOut: &mode)
    NSLog("dual_camera: capture dropped a video frame: %@", String(describing: reason))
  }
}
