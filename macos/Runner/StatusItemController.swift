import Cocoa

/// The menu-bar (NSStatusItem) shell. "Settings…" is wired in a later task; for
/// now Capture + Quit. Actions are injected so this class owns no app logic.
final class StatusItemController: NSObject {
  private let item: NSStatusItem
  private let onCapture: () -> Void
  private let onSettings: () -> Void

  init(onCapture: @escaping () -> Void, onSettings: @escaping () -> Void) {
    self.onCapture = onCapture
    self.onSettings = onSettings
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    item.button?.image = NSImage(
      systemSymbolName: "camera.viewfinder", accessibilityDescription: "Glimpr")
    item.button?.image?.isTemplate = true

    let menu = NSMenu()
    menu.addItem(menuItem(title: "Capture", action: #selector(capture), key: ""))
    menu.addItem(.separator())
    menu.addItem(menuItem(title: "Settings…", action: #selector(settings), key: ","))
    menu.addItem(.separator())
    menu.addItem(menuItem(title: "Quit Glimpr", action: #selector(quit), key: "q"))
    item.menu = menu
  }

  private func menuItem(title: String, action: Selector, key: String) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
    mi.target = self
    return mi
  }

  @objc private func capture() { onCapture() }
  @objc private func settings() { onSettings() }
  @objc private func quit() { NSApp.terminate(nil) }
}
