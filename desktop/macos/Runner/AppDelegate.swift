// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  /// Sparkle: checks the appcast (SUFeedURL) for a newer signed release and
  /// offers it. Only release builds that carry the update key have one, so
  /// development and CI builds never offer to replace themselves.
  private var updater: SPUStandardUpdaterController?

  // MainMenu.xib makes this delegate; its menu outlets are set by now.
  override func awakeFromNib() {
    super.awakeFromNib()
    #if !DEBUG
      let info = Bundle.main.infoDictionary ?? [:]
      let key = info["SUPublicEDKey"] as? String ?? ""
      let feed = info["SUFeedURL"] as? String ?? ""
      if !key.isEmpty && !feed.isEmpty {
        let controller = SPUStandardUpdaterController(
          startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        updater = controller
        addCheckForUpdates(controller)
      }
    #endif
  }

  /// "Check for Updates…" under "About OpenSportsBall" in the app menu.
  private func addCheckForUpdates(_ controller: SPUStandardUpdaterController) {
    guard let appMenu = applicationMenu ?? NSApp.mainMenu?.items.first?.submenu else { return }
    let item = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      keyEquivalent: "")
    item.target = controller
    appMenu.insertItem(item, at: min(1, appMenu.items.count))
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
