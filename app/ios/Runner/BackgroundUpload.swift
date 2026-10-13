// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import BackgroundTasks
import Flutter
import UIKit

/// `opensportsball/background_upload` (lib/src/upload/background.dart):
/// keeps the app running in the background while the upload queue, which
/// runs in Dart, has work.
///
/// iOS 26+: a `BGContinuedProcessingTask`, shown by the system with our
/// progress. It can only be submitted with the app on screen, so if the
/// system ends it, it is submitted again the next time the app is opened.
/// Every version also asks for the usual extra ~30 s on leaving the app.
final class BackgroundUploadPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "opensportsball/background_upload", binaryMessenger: registrar.messenger())
    let instance = BackgroundUploadPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.observeApp()
  }

  private struct Status {
    var title = "Uploading"
    var text = ""
    var permille: Int64 = 0

    init() {}

    init(_ args: Any?) {
      let a = args as? [String: Any] ?? [:]
      title = a["title"] as? String ?? title
      text = a["text"] as? String ?? ""
      permille = min(1000, max(0, (a["permille"] as? NSNumber)?.int64Value ?? 0))
    }
  }

  /// Dart wants the app kept alive.
  private var active = false
  private var status = Status()
  /// The running `BGContinuedProcessingTask` (typed `AnyObject` for iOS < 26).
  private var task: AnyObject?
  /// Identifier of a request submitted but not yet running.
  private var submitted: String?
  private var grace: UIBackgroundTaskIdentifier = .invalid
  private static var registered = false

  private static var prefix: String { (Bundle.main.bundleIdentifier ?? "dev.opensportsball") + ".upload" }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      status = Status(call.arguments)
      if !active {
        active = true
        submit()
        if UIApplication.shared.applicationState == .background { beginGrace() }
      } else {
        show()
      }
      result(true)
    case "update":
      status = Status(call.arguments)
      show()
      result(active)
    case "stop":
      stop()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func observeApp() {
    let nc = NotificationCenter.default
    nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
      [weak self] _ in
      guard let self, self.active else { return }
      self.beginGrace()
    }
    nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
      [weak self] _ in
      guard let self else { return }
      self.endGrace()
      if self.active && self.task == nil && self.submitted == nil { self.submit() }
    }
  }

  private func stop() {
    active = false
    if #available(iOS 26.0, *) {
      if let id = submitted { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id) }
      (task as? BGContinuedProcessingTask)?.setTaskCompleted(success: true)
    }
    submitted = nil
    task = nil
    endGrace()
  }

  // MARK: - Continued processing (iOS 26+)

  private func submit() {
    guard #available(iOS 26.0, *) else { return }
    let scheduler = BGTaskScheduler.shared
    if !Self.registered {
      Self.registered = scheduler.register(forTaskWithIdentifier: "\(Self.prefix).*", using: .main) {
        [weak self] task in
        guard let task = task as? BGContinuedProcessingTask else { return }
        guard let self else {
          task.setTaskCompleted(success: true)
          return
        }
        self.run(task)
      }
      if !Self.registered {
        NSLog("BackgroundUpload: \(Self.prefix).* is missing from BGTaskSchedulerPermittedIdentifiers")
        return
      }
    }
    let id = "\(Self.prefix).\(UUID().uuidString)"
    let request = BGContinuedProcessingTaskRequest(identifier: id, title: status.title, subtitle: status.text)
    request.strategy = .fail // run now or not at all; we can't resubmit from the background
    do {
      try scheduler.submit(request)
      submitted = id
    } catch {
      NSLog("BackgroundUpload: submit failed: \(error)")
    }
  }

  @available(iOS 26.0, *)
  private func run(_ task: BGContinuedProcessingTask) {
    submitted = nil
    guard active else {
      task.setTaskCompleted(success: true)
      return
    }
    self.task = task
    task.progress.totalUnitCount = 1000
    task.expirationHandler = { [weak self, weak task] in
      DispatchQueue.main.async {
        guard let task else { return }
        if let self, self.task === task { self.task = nil }
        task.setTaskCompleted(success: false)
      }
    }
    show()
  }

  private func show() {
    guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
    task.updateTitle(status.title, subtitle: status.text)
    task.progress.completedUnitCount = status.permille
  }

  // MARK: - The extra time on leaving the app (any iOS)

  private func beginGrace() {
    guard grace == .invalid else { return }
    grace = UIApplication.shared.beginBackgroundTask(withName: "upload") { [weak self] in
      self?.endGrace()
    }
  }

  private func endGrace() {
    guard grace != .invalid else { return }
    UIApplication.shared.endBackgroundTask(grace)
    grace = .invalid
  }
}
