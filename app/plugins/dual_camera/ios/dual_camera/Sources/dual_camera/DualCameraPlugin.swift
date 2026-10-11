// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Flutter
import UIKit

/// Platform channel entry point. The contract is in CHANNEL.md.
///
/// Runs on the main thread. Camera work is handed to the open
/// `CameraSession`'s serial queue; results and events come back to the main
/// thread before reaching Flutter.
public class DualCameraPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let textures: FlutterTextureRegistry
  private var eventSink: FlutterEventSink?

  private var camera: CameraSession?
  private var preview: PreviewTexture?
  private var textureId: Int64?

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
    UIDevice.current.isBatteryMonitoringEnabled = true
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = DualCameraPlugin(textures: registrar.textures())
    let methods = FlutterMethodChannel(
      name: "dev.opensportsball/dual_camera", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "dev.opensportsball/dual_camera/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    closeCamera {}
  }

  // MARK: - FlutterStreamHandler

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  /// Thread-safe: hops to the main thread.
  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.eventSink?(event) }
  }

  // MARK: - Methods

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "checkPermissions":
      result(permissions())
    case "requestPermissions":
      requestPermissions(result)
    case "availableLenses":
      result(CameraSession.availableLenses())
    case "open":
      open(args, result)
    case "lockSettings":
      lockSettings(result)
    case "startRecording":
      startRecording(args, result)
    case "stopRecording":
      stopRecording(result)
    case "status":
      result(status())
    case "requestBluetoothPermission":
      // iOS asks for Bluetooth itself when the app first uses it.
      result(true)
    case "setScreenBrightness":
      setScreenBrightness((args["level"] as? NSNumber).map { CGFloat(truncating: $0) })
      result(nil)
    case "setPreviewPaused":
      preview?.setPaused((args["paused"] as? NSNumber)?.boolValue ?? false)
      result(nil)
    case "setKeepScreenOn":
      UIApplication.shared.isIdleTimerDisabled = (args["on"] as? NSNumber)?.boolValue ?? false
      result(nil)
    case "close":
      closeCamera { result(nil) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func permissions() -> [String: Bool] {
    [
      "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
      "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
    ]
  }

  private func requestPermissions(_ result: @escaping FlutterResult) {
    AVCaptureDevice.requestAccess(for: .video) { _ in
      AVCaptureDevice.requestAccess(for: .audio) { _ in
        DispatchQueue.main.async { result(self.permissions()) }
      }
    }
  }

  private func open(_ args: [String: Any], _ result: @escaping FlutterResult) {
    let config: OpenConfig
    do {
      config = try OpenConfig(args)
    } catch let error as CameraError {
      result(error.flutterError)
      return
    } catch {
      result(FlutterError(code: "internal", message: error.localizedDescription, details: nil))
      return
    }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      result(CameraError("permission_denied", "camera permission not granted").flutterError)
      return
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      result(CameraError("permission_denied", "microphone permission not granted").flutterError)
      return
    }
    // Reopening replaces the current camera.
    closeCamera { [weak self] in
      self?.openCamera(config, result)
    }
  }

  private func openCamera(_ config: OpenConfig, _ result: @escaping FlutterResult) {
    let orientation = DeviceInfo.interfaceOrientation()
    let texture = PreviewTexture { [weak self] in
      guard let self, let id = self.textureId else { return }
      self.textures.textureFrameAvailable(id)
    }
    let id = textures.register(texture)
    preview = texture
    textureId = id
    let session = CameraSession(preview: texture) { [weak self] event in self?.emit(event) }
    camera = session

    session.queue.async {
      do {
        var opened = try session.open(config, orientation: orientation)
        opened["textureId"] = id
        DispatchQueue.main.async { result(opened) }
      } catch {
        let flutterError = (error as? CameraError)?.flutterError
          ?? FlutterError(code: "internal", message: error.localizedDescription, details: nil)
        session.close {
          DispatchQueue.main.async {
            self.releaseCamera(ifCurrent: session)
            result(flutterError)
          }
        }
      }
    }
  }

  private func lockSettings(_ result: @escaping FlutterResult) {
    guard let camera else {
      result(CameraError("not_open", "camera is not open").flutterError)
      return
    }
    camera.queue.async {
      camera.lockSettings { outcome in
        DispatchQueue.main.async {
          switch outcome {
          case .success(let locks): result(locks)
          case .failure(let error): result(error.flutterError)
          }
        }
      }
    }
  }

  private func startRecording(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let camera else {
      result(CameraError("not_open", "camera is not open").flutterError)
      return
    }
    guard let directory = args["directory"] as? String, !directory.isEmpty,
          let prefix = args["filePrefix"] as? String, !prefix.isEmpty
    else {
      result(CameraError("io_error", "directory and filePrefix are required").flutterError)
      return
    }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    camera.queue.async {
      camera.startRecording(directory: url, filePrefix: prefix) { outcome in
        DispatchQueue.main.async {
          switch outcome {
          case .success(let ms): result(["startedAtDeviceMs": ms])
          case .failure(let error): result(error.flutterError)
          }
        }
      }
    }
  }

  private func stopRecording(_ result: @escaping FlutterResult) {
    guard let camera else {
      result(CameraError("not_recording", "camera is not open").flutterError)
      return
    }
    camera.queue.async {
      camera.stopRecording { error in
        // Segment events were dispatched to main before this, so they reach
        // Dart before the method result.
        DispatchQueue.main.async {
          if let error { result(error.flutterError) } else { result([String: Any]()) }
        }
      }
    }
  }

  private func status() -> [String: Any] {
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let level = device.batteryLevel
    return [
      "batteryPercent": level < 0 ? -1 : Int((level * 100).rounded()),
      "charging": device.batteryState == .charging || device.batteryState == .full,
      "freeStorageBytes": DeviceInfo.freeStorageBytes(at: camera?.recordingDirectory),
      "thermalState": DeviceInfo.thermalState(),
      "recording": camera?.isRecording ?? false,
    ]
  }

  /// Closes the current camera (finalizing any recording) and releases the
  /// texture. `completion` runs on the main thread.
  private func closeCamera(_ completion: @escaping () -> Void) {
    guard let session = camera else {
      completion()
      return
    }
    session.queue.async {
      session.close {
        DispatchQueue.main.async {
          self.releaseCamera(ifCurrent: session)
          completion()
        }
      }
    }
  }

  // On iOS screen brightness is a system-wide setting that outlives the app,
  // so remember the user's level and put it back whenever we leave.
  private var savedBrightness: CGFloat?
  private var brightnessObservers: [NSObjectProtocol] = []

  private func setScreenBrightness(_ level: CGFloat?) {
    if let level {
      if savedBrightness == nil {
        savedBrightness = UIScreen.main.brightness
        let restore: (Notification) -> Void = { [weak self] _ in self?.restoreBrightness() }
        brightnessObservers = [
          UIApplication.willResignActiveNotification,
          UIApplication.willTerminateNotification,
        ].map { NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main, using: restore) }
      }
      UIScreen.main.brightness = min(max(level, 0), 1)
    } else {
      restoreBrightness()
    }
  }

  private func restoreBrightness() {
    if let saved = savedBrightness { UIScreen.main.brightness = saved }
    savedBrightness = nil
    brightnessObservers.forEach(NotificationCenter.default.removeObserver)
    brightnessObservers = []
  }

  private func releaseCamera(ifCurrent session: CameraSession) {
    guard camera === session else { return }
    camera = nil
    if let id = textureId { textures.unregisterTexture(id) }
    textureId = nil
    preview = nil
  }
}
