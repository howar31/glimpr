import Cocoa

/// The menu-bar (NSStatusItem) shell. "Settings…" is wired in a later task; for
/// now Capture + Quit. Actions are injected so this class owns no app logic.
final class StatusItemController: NSObject {
  private let item: NSStatusItem
  private let onCapture: () -> Void
  private let onSettings: () -> Void
  private let onOpenImage: () -> Void
  private let onOpenRecent: (String) -> Void
  // The "Open Recent" submenu, rebuilt from the Dart-owned recent list.
  private let recentMenu = NSMenu()

  init(onCapture: @escaping () -> Void,
       onSettings: @escaping () -> Void,
       onOpenImage: @escaping () -> Void,
       onOpenRecent: @escaping (String) -> Void) {
    self.onCapture = onCapture
    self.onSettings = onSettings
    self.onOpenImage = onOpenImage
    self.onOpenRecent = onOpenRecent
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    // Brand Viewfinder mark as a template image: macOS tints it to match the
    // menu-bar appearance (white on a dark bar, black on a light one). Falls back
    // to the system viewfinder symbol if the asset is somehow unavailable.
    let mark = NSImage(named: "StatusBarIcon")
      ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Glimpr")
    mark?.isTemplate = true
    item.button?.image = mark

    let menu = NSMenu()
    // App-name header: disabled, non-clickable. action == nil + autoenablesItems
    // (on by default) renders it greyed out; isEnabled = false makes the intent explicit.
    let header = NSMenuItem(title: "Glimpr", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())
    menu.addItem(menuItem(title: "Capture", action: #selector(capture), key: ""))
    menu.addItem(.separator())
    menu.addItem(menuItem(title: "Open Image…", action: #selector(openImage), key: "o"))
    let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
    recentItem.submenu = recentMenu
    menu.addItem(recentItem)
    rebuildRecent([]) // seed the placeholder until Dart pushes the list
    menu.addItem(.separator())
    menu.addItem(menuItem(title: "Settings…", action: #selector(settings), key: ","))
    menu.addItem(.separator())
    menu.addItem(menuItem(title: "Quit Glimpr", action: #selector(quit), key: "q"))
    item.menu = menu
  }

  /// Replace the "Open Recent" submenu with [paths] (newest first). Called from
  /// the image-editor engine via the editor channel whenever the list changes.
  func setRecentImages(_ paths: [String]) {
    rebuildRecent(paths)
  }

  private func rebuildRecent(_ paths: [String]) {
    recentMenu.removeAllItems()
    guard !paths.isEmpty else {
      // action == nil + autoenablesItems greys this out (no recent files yet).
      recentMenu.addItem(NSMenuItem(title: "No Recent Images", action: nil, keyEquivalent: ""))
      return
    }
    for path in paths {
      let mi = NSMenuItem(
        title: (path as NSString).lastPathComponent,
        action: #selector(openRecent(_:)), keyEquivalent: "")
      mi.target = self
      mi.toolTip = path
      mi.representedObject = path
      recentMenu.addItem(mi)
    }
  }

  private func menuItem(title: String, action: Selector, key: String) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
    mi.target = self
    return mi
  }

  @objc private func capture() { onCapture() }
  @objc private func openImage() { onOpenImage() }
  @objc private func openRecent(_ sender: NSMenuItem) {
    if let path = sender.representedObject as? String { onOpenRecent(path) }
  }
  @objc private func settings() { onSettings() }
  @objc private func quit() { NSApp.terminate(nil) }
}
