// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import CoreMotion
import UIKit

/// Reads which way is up, for the `orientation` method: averages a few
/// Core Motion gravity samples and answers with a unit vector in the
/// displayed picture's axes (x to its right, y to its top, z out of the
/// screen), or nil. The recording is upright in the interface, so this is
/// also "up" in the recorded frames. Main thread only.
final class Gravity {
  private let motion = CMMotionManager()
  private var pending: [(([String: Double]?) -> Void)] = []
  /// Tells a read's timeout apart from a later read's.
  private var generation = 0

  private static let samples = 10

  func read(orientation: UIInterfaceOrientation, _ done: @escaping ([String: Double]?) -> Void) {
    guard motion.isDeviceMotionAvailable else { return done(nil) }
    pending.append(done)
    if pending.count > 1 { return } // a read is already running
    generation += 1
    let gen = generation
    var sum = (x: 0.0, y: 0.0, z: 0.0)
    var n = 0
    let finish: () -> Void = { [weak self] in
      guard let self, gen == self.generation, !self.pending.isEmpty else { return }
      self.motion.stopDeviceMotionUpdates()
      let result = n == 0 ? nil : Gravity.upInDisplay(-sum.x, -sum.y, -sum.z, orientation)
      let callbacks = self.pending
      self.pending = []
      callbacks.forEach { $0(result) }
    }
    motion.deviceMotionUpdateInterval = 0.02
    motion.startDeviceMotionUpdates(to: .main) { m, _ in
      guard let g = m?.gravity else { return }
      // Core Motion's gravity points at the ground; up is the opposite.
      sum.x += g.x
      sum.y += g.y
      sum.z += g.z
      n += 1
      if n >= Gravity.samples { finish() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: finish)
  }

  /// Device axes (portrait: x right, y top, z out of the screen) to the
  /// interface's, normalized.
  static func upInDisplay(_ x: Double, _ y: Double, _ z: Double,
                          _ o: UIInterfaceOrientation) -> [String: Double]? {
    let (sx, sy): (Double, Double)
    switch o {
    case .landscapeRight: (sx, sy) = (-y, x)  // top of the phone to the left
    case .landscapeLeft: (sx, sy) = (y, -x)   // top of the phone to the right
    case .portraitUpsideDown: (sx, sy) = (-x, -y)
    default: (sx, sy) = (x, y)
    }
    let len = (sx * sx + sy * sy + z * z).squareRoot()
    guard len > 0 else { return nil }
    return ["x": sx / len, "y": sy / len, "z": z / len]
  }
}

/// Keeps Core Motion running for the `motion` method and sums up each
/// window between calls: up (averaged gravity, as `Gravity` reports it),
/// the fastest rotation and the largest acceleration apart from gravity.
/// The first call starts the sensors and returns an empty window. Main
/// thread only.
final class Motion {
  private let manager = CMMotionManager()
  private var running = false
  private var n = 0
  private var sum = (x: 0.0, y: 0.0, z: 0.0)
  private var maxRotation = 0.0 // rad/s
  private var maxAcceleration = 0.0 // g

  func take(orientation: UIInterfaceOrientation) -> [String: Any] {
    guard manager.isDeviceMotionAvailable else { return ["samples": 0] }
    guard running else {
      start()
      return ["samples": 0]
    }
    var window: [String: Any] = ["samples": n]
    if n > 0 {
      // Core Motion's gravity points at the ground; up is the opposite.
      if let up = Gravity.upInDisplay(-sum.x, -sum.y, -sum.z, orientation) { window["up"] = up }
      window["maxRotationDegPerS"] = maxRotation * 180 / .pi
      window["maxAccelerationG"] = maxAcceleration
    }
    reset()
    return window
  }

  func stop() {
    guard running else { return }
    manager.stopDeviceMotionUpdates()
    running = false
  }

  private func start() {
    running = true
    reset()
    manager.deviceMotionUpdateInterval = 0.04
    manager.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
      guard let self, let m else { return }
      self.sum.x += m.gravity.x
      self.sum.y += m.gravity.y
      self.sum.z += m.gravity.z
      self.n += 1
      let r = m.rotationRate
      self.maxRotation = max(self.maxRotation, (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot())
      let a = m.userAcceleration
      self.maxAcceleration = max(self.maxAcceleration, (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
    }
  }

  private func reset() {
    n = 0
    sum = (0, 0, 0)
    maxRotation = 0
    maxAcceleration = 0
  }
}
