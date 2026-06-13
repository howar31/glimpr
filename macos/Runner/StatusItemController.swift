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
  private let onOpenSaveFolder: () -> Void
  private let onOpenRecent: (String) -> Void
  private let onClearRecent: () -> Void
  // The "Open Recent" submenu, rebuilt from the Dart-owned recent list.
  private let recentMenu = NSMenu()
  // Items whose key-equivalent hint follows a rebindable global action.
  private var hintedItems: [(NSMenuItem, String)] = []
  // Screen recording (macOS 15+): native stop/abort while a recording runs.
  var onRecordStop: (() -> Void)?
  var onRecordAbort: (() -> Void)?
  var onRecordPause: (() -> Void)?
  var onRecordResume: (() -> Void)?
  private var recordPauseItem: NSMenuItem?
  private var recordPausedState = false
  private var recordStartItems: [NSMenuItem] = []
  private var recordControlItems: [NSMenuItem] = []
  private let normalImage: NSImage?
  private var isRecordingState = false

  init(onAction: @escaping (String) -> Void,
       onMenuOpen: @escaping () -> Void,
       onMenuClose: @escaping () -> Void,
       keyHint: @escaping (String) -> (String, UInt)?,
       onSettings: @escaping () -> Void,
       onOpenImage: @escaping () -> Void,
       onOpenSaveFolder: @escaping () -> Void,
       onOpenRecent: @escaping (String) -> Void,
       onClearRecent: @escaping () -> Void) {
    self.onAction = onAction
    self.onMenuOpen = onMenuOpen
    self.onMenuClose = onMenuClose
    self.keyHint = keyHint
    self.onSettings = onSettings
    self.onOpenImage = onOpenImage
    self.onOpenSaveFolder = onOpenSaveFolder
    self.onOpenRecent = onOpenRecent
    self.onClearRecent = onClearRecent
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Brand Viewfinder mark as a template image: macOS tints it to match the
    // menu-bar appearance (white on a dark bar, black on a light one). Falls back
    // to the system viewfinder symbol if the asset is somehow unavailable.
    let mark = NSImage(named: "StatusBarIcon")
      ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Glimpr")
    mark?.isTemplate = true
    normalImage = mark
    super.init()
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
    menu.addItem(globalItem(L.s("Screenshot Region", "截圖框選範圍"), "global.captureArea"))
    menu.addItem(globalItem(L.s("Screenshot Window", "截圖視窗"), "global.captureWindow"))
    menu.addItem(globalItem(L.s("Screenshot Display", "截圖螢幕"), "global.captureScreen"))
    menu.addItem(globalItem(L.s("Screenshot Last Region", "截圖上次範圍"), "global.captureLastRegion"))
    menu.addItem(.separator())
    menu.addItem(globalItem(L.s("Pin Screenshot", "釘選截圖"), "global.pinArea"))
    menu.addItem(globalItem(L.s("Pin Clipboard", "釘選剪貼簿"), "global.pinClipboard"))
    menu.addItem(.separator())
    // Screen recording (macOS 15+ only; on older systems the section is absent).
    // The start items fire the SAME Dart toggle dispatch as the hotkeys; the
    // Stop/Abort pair appears only while a recording runs (see setRecording).
    if #available(macOS 15.0, *) {
      let pause = menuItem(
        title: L.s("Pause Recording", "暫停錄影"), action: #selector(recordPauseToggle), key: "")
      let stop = menuItem(
        title: L.s("Finish Recording", "完成錄影"), action: #selector(recordStop), key: "")
      let abort = menuItem(
        title: L.s("Abort Recording", "中止錄影"), action: #selector(recordAbort), key: "")
      recordPauseItem = pause
      recordControlItems = [pause, stop, abort]
      recordStartItems = [
        globalItem(L.s("Record Region", "錄製框選範圍"), "global.recordRegion"),
        globalItem(L.s("Record Window", "錄製視窗"), "global.recordWindow"),
        globalItem(L.s("Record Display", "錄製螢幕"), "global.recordDisplay"),
        globalItem(L.s("Record Last Region", "錄製上次範圍"), "global.recordLastRegion"),
      ]
      for mi in recordControlItems {
        mi.isHidden = true
        menu.addItem(mi)
      }
      for mi in recordStartItems { menu.addItem(mi) }
      menu.addItem(.separator())
    }
    // Open Editor reveals the warm editor natively (same as the hotkey's end
    // state) — keep the direct path, but hint with the hotkey's binding.
    let open = menuItem(title: L.s("Open Image Editor", "開啟圖片編輯器"), action: #selector(openImage), key: "")
    hintedItems.append((open, "global.openEditor"))
    menu.addItem(open)
    menu.addItem(globalItem(L.s("Open Image Editor with Clipboard", "以剪貼簿開啟圖片編輯器"), "global.openEditorClipboard"))
    let recentItem = NSMenuItem(title: L.s("Open Recent", "開啟最近項目"), action: nil, keyEquivalent: "")
    recentItem.submenu = recentMenu
    menu.addItem(recentItem)
    rebuildRecent([]) // seed the placeholder until Dart pushes the list
    menu.addItem(menuItem(
      title: L.s("Open Save Folder", "開啟儲存資料夾"),
      action: #selector(openSaveFolder), key: ""))
    menu.addItem(.separator())
    menu.addItem(menuItem(title: L.s("Settings…", "設定…"), action: #selector(settings), key: ","))
    menu.addItem(.separator())
    menu.addItem(menuItem(title: L.s("Quit Glimpr", "結束 Glimpr"), action: #selector(quit), key: "q"))
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
      recentMenu.addItem(NSMenuItem(title: L.s("No Recent Images", "沒有最近的圖片"), action: nil, keyEquivalent: ""))
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
    recentMenu.addItem(menuItem(title: L.s("Clear Menu", "清除選單"), action: #selector(clearRecent), key: ""))
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

  /// Recording state: the brand mark's GEOMETRY never changes — no frame, no
  /// dot, no badge — only its COLOR animates: a 1.7 s ease-in-out "breath"
  /// between the bar's idle tone (white on a dark menu bar, #0F172A on a
  /// light one) and recording red #FF453A. Under reduced motion the mark
  /// holds solid red instead. On a graceful stop the breath eases back to
  /// the idle tone (the capture was kept); on abort/failure it snaps back
  /// instantly. Animated by swapping the button image at 20 Hz (negligible
  /// cost, runs only while recording). Also swaps the start items for
  /// Stop/Abort.
  func setRecording(_ active: Bool, graceful: Bool = true) {
    guard active != isRecordingState else { return }
    isRecordingState = active
    recordingTimer?.invalidate() // also cancels an in-flight ease-back
    recordingTimer = nil
    if active {
      recordingPhase = 0
      if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        recordingMix = 1 // solid red, no movement — state stays legible
        item.button?.image = recordingIcon(mix: 1)
      } else {
        recordingMix = 0
        let timer = Timer.scheduledTimer(
          withTimeInterval: 0.05, repeats: true
        ) { [weak self] _ in
          guard let self else { return }
          self.recordingPhase += 0.05
          self.recordingMix = 0.5 - 0.5 * cos(self.recordingPhase * 2 * .pi / 1.7)
          self.item.button?.image = self.recordingIcon(mix: self.recordingMix)
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
        item.button?.image = recordingIcon(mix: 0)
      }
      item.button?.setAccessibilityLabel(L.s("Glimpr, recording", "Glimpr，錄影中"))
    } else {
      item.button?.setAccessibilityLabel("Glimpr")
      let from = recordingMix
      recordingMix = 0
      if graceful, from > 0.02,
         !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        var t: Double = 0
        let timer = Timer.scheduledTimer(
          withTimeInterval: 0.05, repeats: true
        ) { [weak self] tm in
          guard let self else { tm.invalidate(); return }
          t += 0.05
          let k = min(1, t / 0.45)
          if k >= 1 {
            tm.invalidate()
            if self.recordingTimer === tm { self.recordingTimer = nil }
            self.item.button?.image = self.normalImage
          } else {
            let eased = 0.5 - 0.5 * cos(k * .pi)
            self.item.button?.image = self.recordingIcon(mix: from * (1 - eased))
          }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
      } else {
        item.button?.image = normalImage
      }
    }
    for mi in recordControlItems { mi.isHidden = !active }
    for mi in recordStartItems { mi.isHidden = active }
    if !active { setRecordingPaused(false) }
  }

  /// Toggle the Pause/Resume menu item's label to match the session state.
  func setRecordingPaused(_ paused: Bool) {
    recordPausedState = paused
    recordPauseItem?.title = paused
      ? L.s("Resume Recording", "繼續錄影")
      : L.s("Pause Recording", "暫停錄影")
  }

  private var recordingTimer: Timer?
  private var recordingPhase: Double = 0
  private var recordingMix: Double = 0 // 0 = idle tone, 1 = recording red

  /// The brand mark tinted [mix] of the way from the bar's idle tone to
  /// recording red. Idle tones and the red are the design-locked values;
  /// the appearance is re-read every frame so a bar-tint change mid-recording
  /// keeps the correct idle endpoint.
  private func recordingIcon(mix: Double) -> NSImage {
    let size = normalImage?.size ?? NSSize(width: 18, height: 18)
    let dark = item.button?.effectiveAppearance
      .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let idle: (r: CGFloat, g: CGFloat, b: CGFloat) =
      dark ? (1, 1, 1) : (0x0F / 255.0, 0x17 / 255.0, 0x2A / 255.0)
    let red: (r: CGFloat, g: CGFloat, b: CGFloat) =
      (0xFF / 255.0, 0x45 / 255.0, 0x3A / 255.0)
    let t = CGFloat(mix)
    let glyphTint = NSColor(
      srgbRed: idle.r + (red.r - idle.r) * t,
      green: idle.g + (red.g - idle.g) * t,
      blue: idle.b + (red.b - idle.b) * t,
      alpha: 1)
    let mark = normalImage
    let img = NSImage(size: size, flipped: false) { rect in
      if let mark, let tinted = mark.copy() as? NSImage {
        tinted.lockFocus()
        glyphTint.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
      }
      return true
    }
    img.isTemplate = false
    return img
  }

  @objc private func recordStop() { onRecordStop?() }
  @objc private func recordAbort() { onRecordAbort?() }
  @objc private func recordPauseToggle() {
    if recordPausedState { onRecordResume?() } else { onRecordPause?() }
  }

  @objc private func openImage() { onOpenImage() }
  @objc private func openSaveFolder() { onOpenSaveFolder() }
  @objc private func openRecent(_ sender: NSMenuItem) {
    if let path = sender.representedObject as? String { onOpenRecent(path) }
  }
  @objc private func clearRecent() { onClearRecent() }
  @objc private func settings() { onSettings() }
  @objc private func quit() { NSApp.terminate(nil) }
}
