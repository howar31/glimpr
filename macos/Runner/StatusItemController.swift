import Cocoa

/// The menu-bar (NSStatusItem) shell. Every global action gets a menu item
/// whose key-equivalent HINT mirrors the effective (rebindable) hotkey —
/// refreshed on each menu open via [keyHint]. Actions are injected so this
/// class owns no app logic; the global items fire through [onAction], the same
/// Dart dispatcher the real hotkeys use.
final class StatusItemController: NSObject, NSMenuDelegate {
  private let item: NSStatusItem

  /// The menu-bar button, exposed as an anchor view for popovers/share sheets
  /// fired by flows that have no window of their own (e.g. direct captures).
  var anchorButton: NSStatusBarButton? { item.button }
  private let onAction: (String) -> Void
  private let onMenuOpen: () -> Void
  private let onMenuClose: () -> Void
  private let keyHint: (String) -> (String, UInt)?
  private let onSettings: () -> Void
  private let onOpenImage: () -> Void
  private let onOpenRecent: (String) -> Void
  private let onClearRecent: () -> Void
  // The "Open Recent" submenu, rebuilt from the Dart-owned recent list.
  private let recentMenu = NSMenu()
  // Items whose key-equivalent hint follows a rebindable global action.
  private var hintedItems: [(NSMenuItem, String)] = []

  init(onAction: @escaping (String) -> Void,
       onMenuOpen: @escaping () -> Void,
       onMenuClose: @escaping () -> Void,
       keyHint: @escaping (String) -> (String, UInt)?,
       onSettings: @escaping () -> Void,
       onOpenImage: @escaping () -> Void,
       onOpenRecent: @escaping (String) -> Void,
       onClearRecent: @escaping () -> Void) {
    self.onAction = onAction
    self.onMenuOpen = onMenuOpen
    self.onMenuClose = onMenuClose
    self.keyHint = keyHint
    self.onSettings = onSettings
    self.onOpenImage = onOpenImage
    self.onOpenRecent = onOpenRecent
    self.onClearRecent = onClearRecent
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
    menu.delegate = self // refresh the key-equivalent hints on each open
    // App-name header: disabled, non-clickable. action == nil + autoenablesItems
    // (on by default) renders it greyed out; isEnabled = false makes the intent explicit.
    let header = NSMenuItem(title: "Glimpr", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())
    // Global actions, dispatched through the SAME Dart path as the hotkeys.
    // Action-key literals mirror lib/shortcuts/shortcut_actions.dart.
    menu.addItem(globalItem("Capture", "global.captureArea"))
    menu.addItem(globalItem("Capture Window", "global.captureWindow"))
    menu.addItem(globalItem("Capture Display", "global.captureScreen"))
    menu.addItem(globalItem("Capture Last Region", "global.captureLastRegion"))
    menu.addItem(.separator())
    menu.addItem(globalItem("Pin Capture", "global.pinArea"))
    menu.addItem(globalItem("Pin Clipboard", "global.pinClipboard"))
    menu.addItem(.separator())
    // Open Editor reveals the warm editor natively (same as the hotkey's end
    // state) — keep the direct path, but hint with the hotkey's binding.
    let open = menuItem(title: "Open Editor…", action: #selector(openImage), key: "")
    hintedItems.append((open, "global.openEditor"))
    menu.addItem(open)
    menu.addItem(globalItem("Open Editor with Clipboard", "global.openEditorClipboard"))
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

  /// Refresh the global items' key-equivalent hints from the EFFECTIVE
  /// bindings just before the menu shows, so rebinds (and unbinds) reflect.
  func menuWillOpen(_ menu: NSMenu) {
    onMenuOpen() // pause the Carbon hotkeys so combos hit the menu items
    for (mi, actionKey) in hintedItems {
      if let (key, mods) = keyHint(actionKey) {
        mi.keyEquivalent = key
        mi.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: mods)
      } else {
        mi.keyEquivalent = ""
        mi.keyEquivalentModifierMask = []
      }
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    onMenuClose() // restore the Carbon hotkey registrations
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
    // macOS convention: a trailing "Clear Menu" item (Dart owns the list).
    recentMenu.addItem(.separator())
    recentMenu.addItem(menuItem(title: "Clear Menu", action: #selector(clearRecent), key: ""))
  }

  private func menuItem(title: String, action: Selector, key: String) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
    mi.target = self
    return mi
  }

  /// A menu item firing a rebindable global action; its key hint follows the
  /// effective binding (see menuWillOpen).
  private func globalItem(_ title: String, _ actionKey: String) -> NSMenuItem {
    let mi = menuItem(title: title, action: #selector(globalAction(_:)), key: "")
    mi.representedObject = actionKey
    hintedItems.append((mi, actionKey))
    return mi
  }

  @objc private func globalAction(_ sender: NSMenuItem) {
    if let key = sender.representedObject as? String { onAction(key) }
  }

  @objc private func openImage() { onOpenImage() }
  @objc private func openRecent(_ sender: NSMenuItem) {
    if let path = sender.representedObject as? String { onOpenRecent(path) }
  }
  @objc private func clearRecent() { onClearRecent() }
  @objc private func settings() { onSettings() }
  @objc private func quit() { NSApp.terminate(nil) }
}
