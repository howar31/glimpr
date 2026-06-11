import Carbon.HIToolbox
import Cocoa
import FlutterMacOS
import ServiceManagement
import UniformTypeIdentifiers
import os

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var captureChannel: CaptureChannel?
  private var captureController: CaptureController?
  private var statusItem: StatusItemController?
  private var roleChannel: FlutterMethodChannel?
  private var loginChannel: FlutterMethodChannel?
  private var hotkeyController: HotkeyController?
  private var appearanceObservation: NSKeyValueObservation?
  var overlayManager: OverlayManager?
  private var imageEditorWindow: NSWindow?
  private var imageEditorRole: FlutterMethodChannel?
  private var imageEditorChannel: FlutterMethodChannel?
  private var imageEditorDelegate: ImageEditorWindowDelegate?
  private var isPresentingOpenPanel = false
  // A Finder "Open With" path that arrived before the editor Dart side signalled
  // ready (cold start); flushed by the `editorReady` channel call.
  private var pendingOpenPath: String?
  private var pendingClipboard = false
  private var imageEditorReady = false
  // Reached from AppDelegate.application(_:open:) to route external opens.
  static weak var shared: MainFlutterWindow?

  // This window lives on-screen at alpha 0 (warm control engine) and only shows
  // as the Settings window when revealed. While invisible it must NOT be
  // key-eligible — otherwise macOS keeps handing the keyboard to this invisible
  // window (after Settings closes, or on Cmd-Tab back to the app), leaving the
  // capture overlay / image editor unfocused so tool shortcuts don't work. Gating
  // on alpha makes key focus fall through to the actually-visible window instead.
  override var canBecomeKey: Bool { alphaValue > 0 }
  override var canBecomeMain: Bool { alphaValue > 0 }

  override func awakeFromNib() {
    PerfLog.mark("launchBegin")
    MainFlutterWindow.shared = self
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    // Frosted-glass window: host the Flutter view inside a vibrancy view
    // controller whose own view is an NSVisualEffectView (.behindWindow), so the
    // window blurs the desktop behind it; the Flutter view is transparent and
    // layers the design's translucent tint on top. IMPORTANT: do NOT set
    // window.isOpaque = false / backgroundColor = .clear — the behind-window
    // effect view drives the vibrancy itself, and forcing window transparency
    // makes the window swallow / pass through mouse events (dead UI). This recipe
    // mirrors macos_window_utils' MacOSWindowUtilsViewController. Vibrancy is a
    // stable, cross-platform-portable effect (Windows: acrylic), distinct from
    // the macOS-only Liquid Glass deliberately avoided elsewhere.
    self.contentViewController = GlassContentViewController(
      flutterViewController: flutterViewController)
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let capture = CaptureController(manager: { [weak self] in self?.overlayManager })
    self.captureController = capture
    captureChannel = CaptureChannel(
      messenger: flutterViewController.engine.binaryMessenger,
      capture: capture,
      manager: { [weak self] in self?.overlayManager }
    )
    EncodeChannel.register(messenger: flutterViewController.engine.binaryMessenger)
    ClipboardChannel.register(messenger: flutterViewController.engine.binaryMessenger)

    // Native global hotkeys (Carbon RegisterEventHotKey), driven by the control
    // engine's NativeHotkeyRegistrar over `glimpr/hotkeys`.
    hotkeyController = HotkeyController(
      messenger: flutterViewController.engine.binaryMessenger)

    // This window is the debug control; tell its Dart GlimprRoot which role to show.
    let roleChannel = FlutterMethodChannel(
      name: "glimpr/role", binaryMessenger: flutterViewController.engine.binaryMessenger)
    roleChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getRole": result("control")
      // Cmd-W from the settings UI: hide the window (same as the close button).
      case "closeSettings": self?.hideSettings(); result(nil)
      // Settings > Advanced: how many displays to keep warm capture-ready. Read by
      // OverlayManager ONCE at launch, so a change applies on next launch.
      case "getOverlayWarmTarget":
        result(UserDefaults.standard.object(forKey: "overlayWarmTarget") as? Int ?? 2)
      case "setOverlayWarmTarget":
        if let v = call.arguments as? Int {
          UserDefaults.standard.set(max(1, min(8, v)), forKey: "overlayWarmTarget")
        }
        result(nil)
      // Open-Editor global hotkeys (control engine → reveal the warm editor).
      case "openImageEditor": self?.openImageEditor(); result(nil)
      case "openImageEditorClipboard": self?.openImageEditorClipboard(); result(nil)
      // Settings > Advanced: relaunch the app — spawn a detached watcher that
      // re-opens the bundle once this process exits, then terminate normally
      // (so the warm-engine count and other launch-read settings re-apply).
      case "relaunch":
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
          "-c",
          "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; "
            + "/usr/bin/open \"\(bundlePath)\"",
        ]
        try? task.run()
        result(nil)
        NSApp.terminate(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    self.roleChannel = roleChannel

    // Launch-at-login, backed by SMAppService (the OS is the source of truth).
    let loginChannel = FlutterMethodChannel(
      name: "glimpr/login", binaryMessenger: flutterViewController.engine.binaryMessenger)
    loginChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "isEnabled":
        result(SMAppService.mainApp.status == .enabled)
      case "setEnabled":
        let enable = (call.arguments as? Bool) ?? false
        do {
          if enable {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
          result(SMAppService.mainApp.status == .enabled)
        } catch {
          result(FlutterError(code: "login_item", message: "\(error)", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.loginChannel = loginChannel

    super.awakeFromNib()

    // Build + warm the per-display overlay windows/engines now (applicationDid-
    // FinishLaunching isn't reliably called in this nib setup). Each unit warms
    // its engine on-screen at alpha 0; a capture reveals the matching window.
    let manager = OverlayManager()
    manager.startObservingScreens()
    self.overlayManager = manager
    // NOTE: a launch-time 1x1 SCK warm-up screenshot was tried here and did
    // NOT absorb the session's first-capture overhead (~100ms SCK first call
    // regardless) — do not re-add. A persistent SCStream is also off the
    // table: it would pin the macOS "recording" indicator on.

    self.statusItem = StatusItemController(
      // Menu items fire global actions through the SAME Dart dispatcher as
      // the hotkeys; their key hints mirror the effective bindings.
      onAction: { [weak self] key in self?.hotkeyController?.fireAction(key) },
      // Dropdown open -> pause the Carbon hotkeys so combos hit the menu's
      // key equivalents (item fires, menu folds, action runs immediately).
      onMenuOpen: { [weak self] in self?.hotkeyController?.pauseAll() },
      onMenuClose: { [weak self] in self?.hotkeyController?.resumeAll() },
      keyHint: { [weak self] key in
        guard let h = self?.hotkeyController?.keyEquivalent(for: key) else { return nil }
        return (h.key, h.mods.rawValue)
      },
      onSettings: { [weak self] in self?.revealSettings() },
      onOpenImage: { [weak self] in self?.openImageEditor() },
      // A recent item reveals the editor (it may be hidden) then loads the file
      // (confirmed:false → Dart dirty-confirms if an edited image is open).
      onOpenRecent: { [weak self] path in
        self?.openImageEditor()
        self?.imageEditorChannel?.invokeMethod("loadPath", arguments: path)
      },
      // "Clear Menu" → Dart (the editor engine owns the recent list; it clears
      // the store and pushes the empty list back to this submenu).
      onClearRecent: { [weak self] in
        self?.imageEditorChannel?.invokeMethod("clearRecent", arguments: nil)
      })
    PerfLog.mark("statusItemReady")

    // Warm the Image Editor engine + window at launch. A post-launch (on-demand)
    // engine never starts its render loop (only launch-born engines render — a
    // spike confirmed this), so build it now and keep it hidden at alpha 0 (engine
    // stays warm), revealed by "Open Editor…". Mirrors this window's warm pattern.
    setUpImageEditorWindow()

    // Resident: keep the engine warm (on-screen, transparent, click-through) so
    // main() runs + the hotkey registers, but present nothing until "Settings…".
    // Fixed-size settings window (NOT .resizable) with an inline, transparent
    // title bar so the Flutter sidebar runs to the top edge behind the traffic
    // lights (macOS preferences style). The content lays out its own top inset.
    self.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    self.title = "Glimpr Settings"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    // Hard-lock the size. Dropping .resizable from the style mask alone proved
    // unreliable (the window is declared resizable="YES" in MainMenu.xib and the
    // mask override didn't stay applied), so clamp content min == max — AppKit
    // enforces this unconditionally, blocking edge-drag resize and window tiling.
    // Roomier for the denser Shortcuts tab (its many rows scroll within the
    // content ListView; sizing does not try to fit them all without scrolling).
    let fixedSize = NSSize(width: 820, height: 700)
    self.setContentSize(fixedSize)
    self.contentMinSize = fixedSize
    self.contentMaxSize = fixedSize
    // Fixed-size window: disable the green zoom / fullscreen button. This also
    // removes its window-tiling hover menu, whose modal tracking run loop blocked
    // the global capture hotkey (same-process Carbon hotkey) while it was open.
    // AppKit re-enables it on some events (e.g. regaining key after a capture),
    // so it is re-applied in revealSettings + windowDidUpdate.
    disableZoomButton()
    self.isReleasedWhenClosed = false
    // moveToActiveSpace: reveal on the user's current Space. fullScreenNone: this
    // fixed-size window must not go full-screen (greys out View > Enter Full Screen).
    self.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
    self.delegate = self
    // Order front THEN drop alpha (the proven warm-engine order — same as the
    // overlay windows): an on-screen layout pass realizes the Metal surface and
    // runs main(), after which alpha 0 hides it without dropping it off-screen.
    self.orderFrontRegardless()
    self.alphaValue = 0
    self.ignoresMouseEvents = true

    // Dock icon follows the system appearance: dark-glass tile in Dark Mode, the
    // gradient-fill tile in Light Mode. The Dock icon is only visible while the
    // settings window is open (the app is .accessory at rest), but applying it
    // continuously means it is already correct the moment the icon appears.
    updateAppIcon()
    appearanceObservation = NSApp.observe(\.effectiveAppearance, options: []) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.updateAppIcon() }
    }
  }

  /// Swap the running app's Dock icon to match the effective system appearance.
  private func updateAppIcon() {
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if let icon = NSImage(named: isDark ? "AppIconDark" : "AppIconLight") {
      NSApp.applicationIconImage = icon
    }
  }

  /// Show the settings window on the user's CURRENT Space, in front. While it is
  /// visible the app becomes a regular app (Dock icon + Cmd-Tab); it reverts to a
  /// menu-bar accessory when the window is closed (see hideSettings).
  func revealSettings(aboveOverlay: Bool = false) {
    updateAppIcon()
    // Over a paused capture, the freeze sits at the shielding level; raise
    // Settings just above it so it shows on top (restored in hideSettings).
    level = aboveOverlay
      ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
      : .normal
    alphaValue = 1
    ignoresMouseEvents = false
    center()
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    disableZoomButton()
    updateActivationPolicy()
    // Tell the editor Settings is open (ANY path: menu / ⌘,). The editor masks
    // itself while Settings is open AND it isn't the active window.
    imageEditorChannel?.invokeMethod("settingsOpened", arguments: nil)
  }

  private func setUpImageEditorWindow() {
    let vc = FlutterViewController()
    RegisterGeneratedPlugins(registry: vc)
    EncodeChannel.register(messenger: vc.engine.binaryMessenger)
    ClipboardChannel.register(messenger: vc.engine.binaryMessenger)
    let role = FlutterMethodChannel(
      name: "glimpr/role", binaryMessenger: vc.engine.binaryMessenger)
    role.setMethodCallHandler { call, result in
      if call.method == "getRole" {
        result("image-editor")
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.imageEditorRole = role

    let editorChannel = FlutterMethodChannel(
      name: "glimpr/imageEditor", binaryMessenger: vc.engine.binaryMessenger)
    editorChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "openPanel":
        result(self?.presentOpenPanel())
      // Dart asks native to physically hide the editor window (engine stays warm).
      case "hideEditor":
        self?.hideImageEditor()
        result(nil)
      // Dart pushes the recent-images list → rebuild the menu-bar "Open Recent".
      case "setRecentImages":
        if let paths = call.arguments as? [String] {
          self?.statusItem?.setRecentImages(paths)
        }
        result(nil)
      // Dart signals its editor channel handler is installed → flush any path
      // that a Finder "Open With" delivered during a cold start.
      case "editorReady":
        self?.imageEditorReady = true
        self?.flushPendingOpen()
        result(nil)
      // The Flutter title bar covers the native one, so a double-click never
      // reaches AppKit; Dart forwards it here to run the system double-click action.
      case "titleBarDoubleClick":
        self?.handleTitleBarDoubleClick()
        result(nil)
      // ⌘, from the Image Editor (or its landing) reveals the Settings window.
      case "openSettings":
        self?.revealSettings()
        result(nil)
      // Dart-side perf marks from the editor engine (gallery/open/export
      // timings, frame stats) — this engine has no glimpr/capture handler.
      case "perfMark":
        if let label = (call.arguments as? [String: Any])?["label"] as? String {
          PerfLog.mark(label)
        }
        result(nil)
      // Editor Done flow / one-off: share sheet anchored to the menu-bar icon.
      case "shareSheet":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          self?.showShareSheet(path: path)
        }
        result(nil)
      // Editor Done flow / one-off: pin (no origin rect -> centered).
      case "pinImage":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          self?.pinImage(path: path, rect: nil)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.imageEditorChannel = editorChannel

    let w = ImageEditorPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    w.onCloseShortcut = { [weak self] in self?.requestCloseImageEditor() }
    w.title = "Image Editor"
    // Inline, transparent title bar so the Flutter content runs to the top edge
    // behind the traffic lights (same recipe as the settings window). Flutter
    // draws its own 44px title bar; the canvas/toolbar lay out below it.
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    // Wrap the Flutter VC in the behind-window vibrancy controller so the editor
    // window reads as dark frosted glass (mirrors the settings window). The
    // Flutter view is transparent and composites its tint over the vibrancy.
    // An image file dropped on the window forwards its path to Dart (loadPath
    // confirmed:false → Dart dirty-confirms before replacing). Drops only land on
    // a visible window (it is alpha 0 + click-through at rest), so no reveal here.
    w.contentViewController = GlassContentViewController(
      flutterViewController: vc,
      onDropFile: { [weak self] path in
        self?.imageEditorChannel?.invokeMethod("loadPath", arguments: path)
      })
    // contentViewController sizing collapses to the (zero-size) Flutter view;
    // force the default content size + a minimum. The min width must fit the
    // bottom toolbar (12 tools + Fit/100% + undo/redo + Open/Copy/Save) so it
    // never overflows; the min height keeps the landing card (with its recent
    // list) from overflowing.
    w.setContentSize(NSSize(width: 1280, height: 720))
    w.contentMinSize = NSSize(width: 1060, height: 720)
    w.isReleasedWhenClosed = false
    // Centre as the first-run default, THEN bind a frame-autosave name: AppKit
    // restores the user's last size+position if present (overriding the centre),
    // otherwise keeps the centred default — and persists every later move/resize.
    w.center()
    w.setFrameAutosaveName("GlimprImageEditorWindow")
    let delegate = ImageEditorWindowDelegate(
      onClose: { [weak self] in self?.requestCloseImageEditor() },
      onBecomeKey: { [weak self] in
        self?.imageEditorChannel?.invokeMethod("windowBecameKey", arguments: nil)
      },
      onResignKey: { [weak self] in
        self?.imageEditorChannel?.invokeMethod("windowResignedKey", arguments: nil)
      })
    w.delegate = delegate
    self.imageEditorDelegate = delegate
    self.imageEditorWindow = w

    // Warm order (same as this window + the overlays): on-screen front THEN alpha 0
    // — an on-screen layout pass realizes the Metal surface + runs main(); alpha 0
    // then hides it without dropping it off-screen. Click-through while hidden.
    w.orderFrontRegardless()
    w.alphaValue = 0
    w.ignoresMouseEvents = true
  }

  /// Reveal the warm Image Editor window in its landing state. Opening the editor
  /// must NOT auto-pop a file dialog — the in-window Open button (and the
  /// `openPanel` channel method) drive the actual file picking.
  func openImageEditor() {
    guard let w = imageEditorWindow else { return }
    w.alphaValue = 1
    w.ignoresMouseEvents = false
    // No re-centre: the frame-autosave name keeps the user's last size+position.
    updateActivationPolicy()
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
  }

  /// Open an image that arrived from outside the app (Finder "Open With" / an
  /// `openURLs` Apple event). If the editor Dart side has not signalled ready yet
  /// (cold start), buffer the path and flush it on `editorReady`.
  func openImageFromExternal(_ path: String) {
    guard imageEditorReady else {
      pendingOpenPath = path
      return
    }
    openImageEditor()
    imageEditorChannel?.invokeMethod("loadPath", arguments: path)
  }

  /// Reveal the editor and ask it to load the clipboard image. If the editor
  /// Dart is not ready yet (cold start), buffer the request and flush it on
  /// `editorReady`. Mirrors `openImageFromExternal`.
  func openImageEditorClipboard() {
    guard imageEditorReady else {
      pendingClipboard = true
      return
    }
    openImageEditor()
    imageEditorChannel?.invokeMethod("loadClipboard", arguments: nil)
  }

  private func flushPendingOpen() {
    if let path = pendingOpenPath {
      pendingOpenPath = nil
      openImageEditor()
      imageEditorChannel?.invokeMethod("loadPath", arguments: path)
    }
    if pendingClipboard {
      pendingClipboard = false
      openImageEditor()
      imageEditorChannel?.invokeMethod("loadClipboard", arguments: nil)
    }
  }

  /// Present a modal NSOpenPanel restricted to common image types and return the
  /// chosen file path, or nil if the user cancelled. A re-entrancy guard prevents
  /// stacking a second panel if the channel or menu fires while one is already up.
  private func presentOpenPanel() -> String? {
    guard !isPresentingOpenPanel else { return nil }
    isPresentingOpenPanel = true
    defer { isPresentingOpenPanel = false }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .bmp, .heic, .image]
    return panel.runModal() == .OK ? panel.url?.path : nil
  }

  /// Ask Dart to handle a close request (dirty-check + dialog). Dart calls back
  /// `hideEditor` if it decides to proceed; the window is never destroyed (engine
  /// stays warm). Both the red button and Cmd-W route through here.
  private func requestCloseImageEditor() {
    imageEditorChannel?.invokeMethod("requestClose", arguments: nil)
  }

  /// Run the user's configured title-bar double-click action on the editor
  /// window (System Settings › Desktop & Dock › "Double-click a window's title
  /// bar to"). Defaults to zoom when unset, matching AppKit.
  private func handleTitleBarDoubleClick() {
    guard let w = imageEditorWindow else { return }
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize": w.miniaturize(nil)
    case "None": break
    default: w.zoom(nil) // "Maximize" / unset
    }
  }

  // Retains the share picker while it is on screen (it would deallocate — and
  // vanish — the moment the local variable went out of scope).
  private var sharePicker: NSSharingServicePicker?

  /// Show the macOS share sheet for the file at [path], anchored to the
  /// menu-bar status item for EVERY source: capture flows have no window left
  /// by completion time, and the editor's Done closes its window right after
  /// firing the share — a window-anchored picker would die with it. One anchor
  /// keeps the behaviour uniform.
  func showShareSheet(path: String) {
    guard let button = statusItem?.anchorButton else { return }
    let picker = NSSharingServicePicker(items: [URL(fileURLWithPath: path)])
    sharePicker = picker
    picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  /// A capture engine wrote the shared recent-images store: tell the editor
  /// engine to reload it (landing gallery + the menu-bar "Open Recent" submenu).
  func notifyRecentChanged() {
    imageEditorChannel?.invokeMethod("refreshRecent", arguments: nil)
  }

  // The live pin windows; a pin removes itself from here when closed.
  private var pins: [PinPanel] = []

  /// Float the image at [path] as an always-on-top pin window. [rect] is the
  /// GLOBAL top-left-origin logical rect (pin-in-place over the captured
  /// region); nil centers the pin on the main screen at the image's logical
  /// size. Coordinates flip via the primary screen (AppKit is bottom-left).
  func pinImage(path: String, rect: CGRect?) {
    guard let image = NSImage(contentsOfFile: path) else { return }
    let frame: NSRect
    if let r = rect {
      let primaryH = NSScreen.screens.first?.frame.height ?? 0
      frame = NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    } else {
      let screen = NSScreen.main ?? NSScreen.screens.first
      let scale = screen?.backingScaleFactor ?? 2
      // A screenshot PNG carries no DPI metadata, so NSImage.size == pixels;
      // divide by the backing scale for the on-screen logical size.
      let s = NSSize(width: image.size.width / scale, height: image.size.height / scale)
      let sf = screen?.frame ?? .zero
      frame = NSRect(
        x: sf.midX - s.width / 2, y: sf.midY - s.height / 2,
        width: s.width, height: s.height)
    }
    let pin = PinPanel(image: image, frame: frame)
    pins.append(pin)
    pin.onClosed = { [weak self, weak pin] in
      self?.pins.removeAll { $0 === pin }
    }
    pin.orderFrontRegardless()
  }

  private func hideImageEditor() {
    guard let w = imageEditorWindow else { return }
    w.alphaValue = 0
    w.ignoresMouseEvents = true
    w.orderBack(nil)
    updateActivationPolicy()
  }

  private func hideSettings() {
    // Stay ON-SCREEN at alpha 0 (engine must remain warm — never orderOut, which
    // would drop the view off-screen and risk a blank re-show). orderBack tucks it
    // behind everything. Back to accessory: no Dock icon / not in Cmd-Tab at rest,
    // which also keeps the overlay's activate from switching Spaces during capture.
    alphaValue = 0
    ignoresMouseEvents = true
    level = .normal // restore from a possible aboveOverlay raise
    orderBack(nil)
    updateActivationPolicy()
    // If ⌘, paused a capture, resume the freeze now that Settings is gone.
    if overlayManager?.isSuspended == true {
      overlayManager?.resume()
    }
    // If the image editor is the visible window, hand key focus back to it —
    // orderBack alone doesn't reliably re-key with our warm always-on-screen
    // windows, so its windowDidBecomeKey fires and shortcuts resume.
    if let w = imageEditorWindow, w.alphaValue > 0 {
      w.makeKeyAndOrderFront(nil)
    }
    // Settings closed (any path) → the editor drops its mask + hot-reloads.
    imageEditorChannel?.invokeMethod("settingsClosed", arguments: nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideSettings()
    return false
  }

  // Cmd-W closes (hides) the settings window regardless of which Flutter widget
  // holds focus. A focused Flutter text field (e.g. the filename template) can
  // swallow the in-Flutter Cmd-W shortcut, so intercept the key equivalent at the
  // window — ahead of the FlutterView — whenever settings is actually visible.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if alphaValue > 0,
      event.modifierFlags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "w"
    {
      hideSettings()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  // Belt-and-suspenders with the disabled zoom button: never zoom this window.
  func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
    false
  }

  // AppKit re-enables the zoom (green) button on various events — notably when
  // the window regains key/main focus after a capture. Re-disable it whenever the
  // window updates so it stays inert (and its tiling hover menu stays suppressed).
  func windowDidUpdate(_ notification: Notification) {
    disableZoomButton()
  }

  private func disableZoomButton() {
    standardWindowButton(.zoomButton)?.isEnabled = false
  }

  /// Regular app (Dock icon + Cmd-Tab) while EITHER the settings or the image
  /// editor window is visible (alpha > 0); a menu-bar accessory at rest.
  private func updateActivationPolicy() {
    let editorVisible = (imageEditorWindow?.alphaValue ?? 0) > 0
    let settingsVisible = alphaValue > 0
    // While a capture is paused for the Settings detour (⌘, from the overlay), stay
    // .accessory. Flipping to .regular for Settings and back to .accessory on close
    // deactivates the app on the next runloop turn, stealing focus from the
    // shield-level overlay — so the overlay would never get the keyboard back.
    let overlayCapture = overlayManager?.isSuspended == true
    let regular = (editorVisible || settingsVisible) && !overlayCapture
    NSApp.setActivationPolicy(regular ? .regular : .accessory)
  }
}

/// Hosts the Flutter view on top of a behind-window NSVisualEffectView so the
/// settings window reads as frosted glass over the desktop. The Flutter view is
/// added as a CHILD view controller (keeping the responder chain intact so input
/// works) and made transparent so the vibrancy and the Flutter tint composite.
/// Mirrors the recipe used by macos_window_utils — crucially, the window itself
/// is left opaque (the behind-window effect view drives the vibrancy; forcing the
/// window transparent breaks mouse-event delivery).
class GlassContentViewController: NSViewController {
  private let flutterViewController: FlutterViewController
  private let onDropFile: ((String) -> Void)?

  init(flutterViewController: FlutterViewController,
       onDropFile: ((String) -> Void)? = nil) {
    self.flutterViewController = flutterViewController
    self.onDropFile = onDropFile
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func loadView() {
    let effectView = DragDestinationEffectView()
    effectView.autoresizingMask = [.width, .height]
    effectView.blendingMode = .behindWindow
    effectView.state = .followsWindowActiveState
    effectView.material = .sidebar
    // Only the Image Editor window passes a drop handler — register for file
    // drags there so an image dropped anywhere on the window loads/replaces the
    // canvas. The settings window passes nil and never accepts drops.
    if let onDropFile = onDropFile {
      effectView.onDropFile = onDropFile
      effectView.registerForDraggedTypes([.fileURL])
    }
    self.view = effectView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    addChild(flutterViewController)
    let flutterView = flutterViewController.view
    flutterView.frame = view.bounds
    flutterView.autoresizingMask = [.width, .height]
    // Flutter 3.7+ defaults the view background to black — clear it so the
    // vibrancy behind shows through the transparent parts of the UI.
    flutterViewController.backgroundColor = .clear
    view.addSubview(flutterView)
  }
}

/// An NSVisualEffectView that also acts as a file drag destination. The Flutter
/// view sits on top but is NOT registered for dragged types, so AppKit falls
/// through to this superview for drops. Used by the Image Editor window to accept
/// an image file dropped anywhere on the canvas/landing area; the dropped path is
/// forwarded to Dart (which dirty-confirms before replacing the current image).
final class DragDestinationEffectView: NSVisualEffectView {
  var onDropFile: ((String) -> Void)?

  /// The first dropped file URL whose content conforms to public.image, or nil.
  private func imageURL(_ sender: NSDraggingInfo) -> URL? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]
    let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: options) as? [URL]
    return urls?.first
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    (onDropFile != nil && imageURL(sender) != nil) ? .copy : []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    (onDropFile != nil && imageURL(sender) != nil) ? .copy : []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let handler = onDropFile, let url = imageURL(sender) else { return false }
    handler(url.path)
    return true
  }
}

/// The Image Editor window. Subclassed only to intercept Cmd-W at the window
/// level so it hides the editor (keeping the engine warm), exactly like the
/// settings window — a focused Flutter text field can swallow the in-Flutter
/// shortcut, so the close key must be handled natively. Mirrors
/// MainFlutterWindow.performKeyEquivalent.
final class ImageEditorPanel: NSWindow {
  var onCloseShortcut: (() -> Void)?
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if alphaValue > 0,
      event.modifierFlags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "w"
    {
      onCloseShortcut?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// Routes the Image Editor window's close button to "hide" (keep the engine
/// warm) instead of destroying the window — a dedicated delegate so it does not
/// collide with MainFlutterWindow's own NSWindowDelegate (the settings window).
final class ImageEditorWindowDelegate: NSObject, NSWindowDelegate {
  private let onClose: () -> Void
  private let onBecomeKey: () -> Void
  private let onResignKey: () -> Void
  init(onClose: @escaping () -> Void,
       onBecomeKey: @escaping () -> Void,
       onResignKey: @escaping () -> Void) {
    self.onClose = onClose
    self.onBecomeKey = onBecomeKey
    self.onResignKey = onResignKey
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    onClose()
    return false
  }
  // Active-window tracking → the editor derives its mask from (Settings open AND
  // not active) and hot-reloads when it becomes active.
  func windowDidBecomeKey(_ notification: Notification) { onBecomeKey() }
  func windowDidResignKey(_ notification: Notification) { onResignKey() }
}

/// Native global hotkeys via Carbon `RegisterEventHotKey` (replaces the
/// hotkey_manager plugin). The control engine's Dart `NativeHotkeyRegistrar`
/// sends a keyCode + Carbon modifier mask over `glimpr/hotkeys`; a fired hotkey
/// invokes `onHotkey(actionKey)` back to Dart. Carbon is non-exclusive (no
/// third-party-conflict detection), matching the previous plugin behaviour.
final class HotkeyController {
  private let channel: FlutterMethodChannel
  private var refs: [String: EventHotKeyRef] = [:] // actionKey -> ref
  private var actionForId: [UInt32: String] = [:] // EventHotKeyID.id -> actionKey
  private var nextId: UInt32 = 1
  private var handlerInstalled = false
  // The live registrations' specs, kept so pauseAll/resumeAll can drop and
  // re-create the Carbon registrations without Dart's involvement.
  private var specs: [String: (keyCode: UInt32, modifiers: UInt32)] = [:]
  // Display hints for the menu-bar items: the EFFECTIVE binding's key
  // character + Cocoa modifier mask per action, pushed by Dart on register.
  private var hints: [String: (key: String, mods: NSEvent.ModifierFlags)] = [:]



  /// The effective binding's menu key-equivalent for [actionKey], or nil when
  /// unbound / not registrable as a one-character equivalent.
  func keyEquivalent(for actionKey: String) -> (key: String, mods: NSEvent.ModifierFlags)? {
    hints[actionKey]
  }

  /// Fire [actionKey] exactly as if its global hotkey was pressed — used by
  /// the menu-bar items so both paths share the Dart-side dispatcher.
  func fireAction(_ actionKey: String) {
    PerfLog.mark("hotkey \(actionKey) src=menu")
    channel.invokeMethod("onHotkey", arguments: actionKey)
  }

  /// While the status menu is open, Carbon registrations are dropped (specs
  /// and menu hints stay): a registered combo is swallowed system-wide and
  /// its handler deferred by menu tracking, whereas a PLAIN key event matches
  /// the open menu's key equivalents — the item fires, the menu folds, and
  /// the action dispatches immediately. The one mechanism that works on
  /// macOS 26 (dispatcher-target handlers and local monitors both stay silent
  /// during the out-of-process menu tracking).
  func pauseAll() {
    for (_, ref) in refs { UnregisterEventHotKey(ref) }
    refs.removeAll()
    actionForId.removeAll()
  }

  /// Re-create the Carbon registrations dropped by [pauseAll].
  func resumeAll() {
    for (actionKey, spec) in specs {
      _ = register(actionKey: actionKey, keyCode: spec.keyCode, modifiers: spec.modifiers)
    }
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "glimpr/hotkeys", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
    switch call.method {
    case "register":
      guard let a = call.arguments as? [String: Any],
        let id = a["id"] as? String,
        let keyCode = a["keyCode"] as? Int,
        let modifiers = a["modifiers"] as? Int
      else { result(false); return }
      let ok = register(actionKey: id, keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
      if ok, let keyChar = a["keyChar"] as? String, !keyChar.isEmpty,
         let cocoaMods = a["cocoaMods"] as? Int {
        hints[id] = (keyChar, NSEvent.ModifierFlags(rawValue: UInt(cocoaMods)))
      }
      result(ok)
    case "unregister":
      if let a = call.arguments as? [String: Any], let id = a["id"] as? String {
        unregister(actionKey: id)
      }
      result(nil)
    case "unregisterAll":
      unregisterAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// One process-wide Carbon handler that routes a fired hotkey by its id.
  private func ensureHandler() {
    guard !handlerInstalled else { return }
    handlerInstalled = true
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { (_, event, userData) -> OSStatus in
        guard let userData = userData, let event = event else { return noErr }
        var hkID = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue().fire(hkID.id)
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
  }

  private func fire(_ id: UInt32) {
    guard let actionKey = actionForId[id] else { return }
    PerfLog.mark("hotkey \(actionKey) src=carbon")
    channel.invokeMethod("onHotkey", arguments: actionKey)
  }

  private func register(actionKey: String, keyCode: UInt32, modifiers: UInt32) -> Bool {
    ensureHandler()
    // Replace any existing Carbon ref ONLY — the spec/hint stay (resumeAll
    // re-registers through here; dropping the hint here erased the menu's
    // key-equivalents after the first pause/resume cycle).
    removeRef(actionKey)
    let id = nextId
    nextId += 1
    let hotKeyID = EventHotKeyID(signature: OSType(0x474C_4D52 /* 'GLMR' */), id: id)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    if status == noErr, let ref = ref {
      refs[actionKey] = ref
      actionForId[id] = actionKey
      specs[actionKey] = (keyCode, modifiers)
      return true
    }
    return false
  }

  /// Full removal (Dart unbound the action): ref + spec + menu hint all go.
  private func unregister(actionKey: String) {
    hints.removeValue(forKey: actionKey)
    specs.removeValue(forKey: actionKey)
    removeRef(actionKey)
  }

  /// Drop just the live Carbon registration, keeping spec + hint (used by
  /// register's replace path and indirectly by pauseAll/resumeAll).
  private func removeRef(_ actionKey: String) {
    if let ref = refs.removeValue(forKey: actionKey) {
      UnregisterEventHotKey(ref)
      actionForId = actionForId.filter { $0.value != actionKey }
    }
  }

  private func unregisterAll() {
    for (_, ref) in refs { UnregisterEventHotKey(ref) }
    refs.removeAll()
    actionForId.removeAll()
    specs.removeAll()
    hints.removeAll()
  }
}

// MARK: - Pin to screen

/// A floating "pin": a captured image as an always-on-top borderless panel —
/// a reference snippet that stays over everything until closed. The window is
/// LARGER than the image by a transparent margin so the hover corona can glow
/// OUTWARD past the image edge. Drag anywhere to move; scroll wheel zooms
/// 25%–300%; hovering for 2s reveals the Aurora corona (rotating brand-gradient
/// halo radiating out from the edge) + a glass close button (top-right, hover-
/// reactive, follows light/dark). Right-click: Reset Size / Save As / Copy /
/// Close. Pure AppKit BY NECESSITY: pins are created at runtime and post-launch
/// Flutter engines never start a render loop.
final class PinPanel: NSPanel {
  /// Transparent margin around the image — the vapor's reach. Must exceed the
  /// glow's worst case (max shadowRadius ~20 × ~2 visual falloff + drift ±8)
  /// or the halo clips with a hard edge at the window border.
  private static let margin: CGFloat = 56
  private let baseSize: NSSize // IMAGE logical size at 100%
  private var zoom: CGFloat = 1
  private let pinnedImage: NSImage
  private var hoverTimer: Timer?
  private var imageView: NSImageView!
  private var closeWrap: NSVisualEffectView!
  private var closeHoverLayer: CALayer!
  private var closeButton: NSButton!
  private var vaporContainer: CALayer!
  private var vaporLayers: [CALayer] = []
  var onClosed: (() -> Void)?

  /// Pins are free-floating references that must reach the screen edges, so
  /// every programmatic constrain pass (display reconfiguration, zoom
  /// setFrame) is a pass-through. NOTE this does NOT cover dragging:
  /// performDrag hands the move to the WindowServer, which enforces its own
  /// menu-bar top clamp out-of-process (verified: this method is not called
  /// per-frame during a drag) — that is why the drag below is manual.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?)
    -> NSRect
  {
    frameRect
  }

  /// [imageFrame] is where the IMAGE sits on screen (AppKit coords); the
  /// window itself extends [margin] beyond it on every side.
  init(image: NSImage, frame imageFrame: NSRect) {
    baseSize = imageFrame.size
    pinnedImage = image
    let m = Self.margin
    super.init(
      contentRect: imageFrame.insetBy(dx: -m, dy: -m),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    isOpaque = false
    hasShadow = true
    isReleasedWhenClosed = false
    backgroundColor = .clear

    let content = PinContentView(frame: NSRect(origin: .zero, size: self.frame.size))
    content.interactiveInset = m // clicks land only on the image, not the halo
    content.wantsLayer = true

    // Aurora vapor, BEHIND the image (added before the image subview): three
    // soft shadow layers in the brand cyan / blue / violet, cast outward from
    // the image edge (shadowPath = the image rect; no fill — only the halo
    // shows past the image). Each drifts and breathes on its own slow period,
    // so the colours mingle like vapor. Hidden until the 2s hover reveal.
    let container = CALayer()
    container.opacity = 0
    let brand: [NSColor] = [
      NSColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1), // cyan
      NSColor(red: 0.38, green: 0.65, blue: 0.98, alpha: 1), // blue
      NSColor(red: 0.65, green: 0.55, blue: 0.98, alpha: 1), // violet
    ]
    for color in brand {
      let v = CALayer()
      v.backgroundColor = NSColor.clear.cgColor
      v.shadowColor = color.cgColor
      v.shadowOpacity = 0.85
      v.shadowOffset = .zero
      v.shadowRadius = 14
      container.addSublayer(v)
      vaporLayers.append(v)
    }
    content.layer?.addSublayer(container)
    vaporContainer = container

    let iv = NSImageView(frame: content.bounds.insetBy(dx: m, dy: m))
    iv.image = image
    iv.imageScaling = .scaleProportionallyUpOrDown
    iv.autoresizingMask = [.width, .height]
    content.addSubview(iv)
    imageView = iv

    // Glass close button, top-right of the IMAGE, hidden until the hover
    // reveal. Popover material + semantic colors follow light/dark; its own
    // hover state brightens the glyph and washes the circle so it reads as
    // clickable.
    let wrap = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    wrap.material = .popover
    wrap.blendingMode = .withinWindow
    wrap.state = .active
    wrap.wantsLayer = true
    wrap.layer?.cornerRadius = 12
    wrap.layer?.masksToBounds = true
    wrap.alphaValue = 0
    wrap.isHidden = true // not hit-testable until the hover reveal
    let hover = CALayer()
    hover.frame = wrap.bounds
    hover.cornerRadius = 12
    hover.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    hover.opacity = 0
    wrap.layer?.addSublayer(hover)
    closeHoverLayer = hover
    let button = NSButton(frame: wrap.bounds)
    button.isBordered = false
    button.image = NSImage(
      systemSymbolName: "xmark", accessibilityDescription: "Close")?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
    button.contentTintColor = .secondaryLabelColor
    button.target = self
    button.action = #selector(closePin)
    wrap.addSubview(button)
    content.addSubview(wrap)
    closeWrap = wrap
    closeButton = button

    // Two tracking areas: the IMAGE (delayed vapor reveal — the transparent
    // halo margin must not trigger it) + the close button (immediate hover
    // affordance), told apart via userInfo.
    iv.addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil))
    wrap.addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: ["close": true]))
    contentView = content
    layoutChrome()
  }

  // A non-activating reference window: never steals the keyboard.
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// Keep the corona + close button tracking the current size (init and after
  /// every zoom/reset resize).
  private func layoutChrome() {
    guard let bounds = contentView?.bounds else { return }
    let m = Self.margin
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    vaporContainer.frame = bounds
    let imageRect = bounds.insetBy(dx: m, dy: m)
    for v in vaporLayers {
      v.frame = bounds
      v.shadowPath = CGPath(
        roundedRect: imageRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
    }
    CATransaction.commit()
    closeWrap.setFrameOrigin(NSPoint(
      x: bounds.width - m - closeWrap.frame.width - 8,
      y: bounds.height - m - closeWrap.frame.height - 8))
  }

  // Drag anywhere: MANUAL drag loop (NSImageView swallows the implicit
  // movable-by-background path, and performDrag is no alternative — the
  // WindowServer's out-of-process drag enforces a menu-bar top clamp that
  // stops the window's halo edge ~margin short of the screen top and cannot
  // be disabled from NSWindow). setFrameOrigin is unconstrained, and the
  // grabbed point stays under the on-screen cursor, so the pin can reach
  // every edge yet never strands out of reach.
  private var dragOffset: NSPoint?

  override func mouseDown(with event: NSEvent) {
    let mouse = NSEvent.mouseLocation
    dragOffset = NSPoint(x: mouse.x - frame.origin.x, y: mouse.y - frame.origin.y)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let off = dragOffset else { return }
    let mouse = NSEvent.mouseLocation
    setFrameOrigin(NSPoint(x: mouse.x - off.x, y: mouse.y - off.y))
  }

  override func mouseUp(with event: NSEvent) {
    dragOffset = nil
  }

  override func rightMouseDown(with event: NSEvent) {
    let menu = NSMenu()
    func add(_ title: String, _ action: Selector) {
      let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
      mi.target = self
      menu.addItem(mi)
    }
    add("Reset Size", #selector(resetSize))
    add("Save As…", #selector(saveAs))
    add("Copy to Clipboard", #selector(copyImage))
    menu.addItem(.separator())
    add("Close Pin", #selector(closePin))
    if let v = contentView {
      NSMenu.popUpContextMenu(menu, with: event, for: v)
    }
  }

  // The pin-wide hover reveal is DELAYED 2s — the pin should feel like part of
  // the screen until the user deliberately rests on it; then the corona marks
  // it and the close button appears. The close button's OWN hover (userInfo-
  // tagged tracking area) reacts immediately so it reads as clickable.
  override func mouseEntered(with event: NSEvent) {
    if (event.trackingArea?.userInfo?["close"] as? Bool) == true {
      setCloseHover(true)
      return
    }
    hoverTimer?.invalidate()
    // Nominal 1s dwell before the reveal — no compensation games for fade /
    // timer-coalescing perception (owner call, 2026-06-10).
    hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) {
      [weak self] _ in self?.reveal(true)
    }
  }

  override func mouseExited(with event: NSEvent) {
    if (event.trackingArea?.userInfo?["close"] as? Bool) == true {
      setCloseHover(false)
      return
    }
    hoverTimer?.invalidate()
    hoverTimer = nil
    reveal(false)
  }

  private func setCloseHover(_ on: Bool) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.15)
    closeHoverLayer.opacity = on ? 1 : 0
    CATransaction.commit()
    closeButton.contentTintColor = on ? .labelColor : .secondaryLabelColor
    (on ? NSCursor.pointingHand : NSCursor.arrow).set()
  }

  private var revealed = false

  private func reveal(_ on: Bool) {
    revealed = on
    // The vapor replaces the window shadow while shown: leaving hasShadow on
    // makes AppKit recompute the borderless window's shadow ALONG THE VAPOR'S
    // translucent edge — a dark rounded rim around the glow (a WindowServer
    // shadow element, which is also why SCK-based captures don't see it).
    // On reveal it goes off IMMEDIATELY; on hide it comes back only AFTER the
    // vapor has fully faded (restoring it mid-fade flashes the dark rim).
    if on { hasShadow = false }
    // isHidden gates hit-testing AND the button's hover tracking — an
    // invisible ✕ must not be clickable.
    if on { closeWrap.isHidden = false }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.25
      closeWrap.animator().alphaValue = on ? 1 : 0
    }, completionHandler: { [weak self] in
      guard let self = self, !on, !self.revealed else { return }
      self.closeWrap.isHidden = true
      self.hasShadow = true
      self.invalidateShadow()
    })
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.25)
    vaporContainer.opacity = on ? 1 : 0
    CATransaction.commit()
    if on {
      // Per-layer organic motion: a slow Lissajous drift (different x/y
      // periods per colour) + a breathing blur radius. The mismatched periods
      // keep the three colours weaving — vapor, not a rigid ring.
      for (i, v) in vaporLayers.enumerated() {
        let fi = Double(i)
        let dx = CABasicAnimation(keyPath: "position.x")
        dx.byValue = 5 + fi * 1.5
        dx.duration = 2.3 + fi * 0.7
        dx.autoreverses = true
        dx.repeatCount = .infinity
        dx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        v.add(dx, forKey: "driftX")
        let dy = CABasicAnimation(keyPath: "position.y")
        dy.byValue = -4 - fi * 1.5
        dy.duration = 3.1 + fi * 0.5
        dy.autoreverses = true
        dy.repeatCount = .infinity
        dy.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        v.add(dy, forKey: "driftY")
        let breathe = CABasicAnimation(keyPath: "shadowRadius")
        breathe.fromValue = 9 + fi * 2
        breathe.toValue = 16 + fi * 2
        breathe.duration = 2.0 + fi * 0.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        v.add(breathe, forKey: "breathe")
      }
    } else {
      for v in vaporLayers { v.removeAllAnimations() }
    }
    invalidateShadow()
  }

  override func scrollWheel(with event: NSEvent) {
    // Gentle steps (a full notch ≈ a few %); clamp to 25%–300% of the ORIGINAL
    // logical size so a runaway scroll can never lose the pin.
    let factor = 1 + event.scrollingDeltaY * 0.0025
    setZoom(min(3, max(0.25, zoom * factor)))
  }

  private func setZoom(_ z: CGFloat) {
    zoom = z
    let m = Self.margin
    let s = NSSize(
      width: baseSize.width * zoom + m * 2,
      height: baseSize.height * zoom + m * 2)
    let c = NSPoint(x: frame.midX, y: frame.midY)
    setFrame(
      NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height),
      display: true)
    layoutChrome()
  }

  @objc private func resetSize() { setZoom(1) }

  @objc private func saveAs() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "pin.png"
    panel.level = .floating // stay reachable above this floating pin
    NSApp.activate(ignoringOtherApps: true)
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self = self else { return }
      guard let tiff = self.pinnedImage.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
      else { return }
      try? png.write(to: url)
    }
  }

  @objc private func copyImage() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([pinnedImage])
  }

  @objc private func closePin() {
    hoverTimer?.invalidate()
    orderOut(nil)
    onClosed?()
  }
}

/// The pin's content view: hit-testing is limited to the IMAGE rect (the
/// transparent vapor margin must not swallow clicks meant for whatever sits
/// under the halo).
final class PinContentView: NSView {
  var interactiveInset: CGFloat = 0
  override func hitTest(_ point: NSPoint) -> NSView? {
    let p = convert(point, from: superview)
    guard bounds.insetBy(dx: interactiveInset, dy: interactiveInset).contains(p)
    else { return nil }
    return super.hitTest(point)
  }
}

/// Perf instrumentation: named marks in the unified log (subsystem = bundle
/// id, category "perf"). Near-zero cost when no log consumer is attached; the
/// unified log supplies the timestamps. Extract with:
///   log show --last 5m --info \
///     --predicate 'subsystem == "com.howar31.glimpr" AND category == "perf"'
enum PerfLog {
  static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "glimpr", category: "perf")
  static func mark(_ label: String) {
    logger.log("PERF \(label, privacy: .public)")
  }
}
