// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Flutter
import Foundation
import UIKit

/// An error with one of the codes from CHANNEL.md.
struct CameraError: Error, LocalizedError {
  let code: String
  let message: String

  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }

  var errorDescription: String? { message }
  var flutterError: FlutterError { FlutterError(code: code, message: message, details: nil) }
}

/// Arguments of the `open` method.
struct OpenConfig {
  let width: Int
  let height: Int
  let fps: Int
  let codec: String
  let bitrateBps: Int
  let lens: String
  let segmentDurationMs: Int
  let lockExposure: Bool

  init(_ args: [String: Any]) throws {
    func int(_ key: String) throws -> Int {
      guard let n = args[key] as? NSNumber else {
        throw CameraError("unsupported_config", "missing or invalid '\(key)'")
      }
      return n.intValue
    }
    width = try int("width")
    height = try int("height")
    fps = try int("fps")
    bitrateBps = try int("bitrateBps")
    segmentDurationMs = try int("segmentDurationMs")
    codec = (args["codec"] as? String) ?? "hevc"
    lens = (args["lens"] as? String) ?? "ultrawide"
    lockExposure = (args["lockExposure"] as? NSNumber)?.boolValue ?? false
    guard width > 0, height > 0, fps > 0, bitrateBps > 0, segmentDurationMs >= 1000 else {
      throw CameraError("unsupported_config", "width, height, fps, bitrateBps must be positive and segmentDurationMs >= 1000")
    }
  }
}

enum DeviceInfo {
  static let lowStorageBytes: Int64 = 500 * 1024 * 1024

  /// Free space usable for important (user-initiated) data on the volume
  /// holding `url`, or the app's Documents directory.
  static func freeStorageBytes(at url: URL?) -> Int64 {
    var target = url ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    // The directory may not exist yet; walk up to one that does.
    while !FileManager.default.fileExists(atPath: target.path) && target.pathComponents.count > 1 {
      target.deleteLastPathComponent()
    }
    // Fresh URL so a cached resource value is never returned.
    let fresh = URL(fileURLWithPath: target.path)
    let values = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
  }

  static func thermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "serious"
    }
  }

  /// Interface orientation of the app's foreground window scene. Main
  /// thread only.
  static func interfaceOrientation() -> UIInterfaceOrientation {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    guard let scene else { return .landscapeRight }
    return scene.effectiveGeometry.interfaceOrientation
  }

  static func interruptionReason(_ notification: Notification) -> String {
    guard let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber,
          let reason = AVCaptureSession.InterruptionReason(rawValue: raw.intValue)
    else { return "unknown" }
    switch reason {
    case .videoDeviceNotAvailableInBackground: return "backgrounded"
    case .audioDeviceInUseByAnotherClient: return "microphone_in_use"
    case .videoDeviceInUseByAnotherClient: return "camera_in_use"
    case .videoDeviceNotAvailableWithMultipleForegroundApps: return "multiple_foreground_apps"
    case .videoDeviceNotAvailableDueToSystemPressure: return "system_pressure"
    default: return "other_\(raw.intValue)"
    }
  }
}
