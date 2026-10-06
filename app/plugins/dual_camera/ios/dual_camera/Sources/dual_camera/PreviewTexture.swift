// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Flutter
import Foundation

/// Flutter texture that shows the latest camera frame.
///
/// The capture queue stores each new frame with `update`; Flutter's raster
/// thread pulls it with `copyPixelBuffer`. The two only share a pointer
/// swap under a lock, so the raster thread never blocks capture for longer
/// than a retain. The buffers are the camera's own (NV12, at recording
/// size); Flutter's Metal external texture wraps them without copying.
final class PreviewTexture: NSObject, FlutterTexture {
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var notifyPending = false
  private let onFrameAvailable: () -> Void

  /// `onFrameAvailable` is called on the main thread, at most once per
  /// frame actually consumed, so a busy main thread can't build a backlog.
  init(onFrameAvailable: @escaping () -> Void) {
    self.onFrameAvailable = onFrameAvailable
  }

  func update(_ pixelBuffer: CVPixelBuffer) {
    lock.lock()
    latest = pixelBuffer
    let shouldNotify = !notifyPending
    notifyPending = true
    lock.unlock()
    guard shouldNotify else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.notifyPending = false
      self.lock.unlock()
      self.onFrameAvailable()
    }
  }

  func clear() {
    lock.lock()
    latest = nil
    lock.unlock()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }
}
