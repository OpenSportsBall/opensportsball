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
