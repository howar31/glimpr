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
