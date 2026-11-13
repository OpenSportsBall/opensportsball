// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Room for the pitch panorama beside the games list.
    let size = NSSize(width: 1320, height: 860)
    let screen = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
    let frame = NSRect(
      x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
      width: min(size.width, screen.width), height: min(size.height, screen.height))
    self.contentViewController = flutterViewController
    self.setFrame(frame, display: true)
    self.minSize = NSSize(width: 1000, height: 680)
    self.title = "OpenSportsBall"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
