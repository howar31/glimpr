import Carbon.HIToolbox
import Cocoa
import FlutterMacOS
import ServiceManagement
import UniformTypeIdentifiers

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

  override func awakeFromNib() {
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

    self.statusItem = StatusItemController(
      onCapture: { [weak self] in self?.captureController?.triggerCapture() },
      onSettings: { [weak self] in self?.revealSettings() },
      onOpenImage: { [weak self] in self?.openImageEditor() },
      // A recent item reveals the editor (it may be hidden) then loads the file
      // (confirmed:false → Dart dirty-confirms if an edited image is open).
      onOpenRecent: { [weak self] path in
        self?.openImageEditor()
        self?.imageEditorChannel?.invokeMethod("loadPath", arguments: path)
      })

    // Warm the Image Editor engine + window at launch. A post-launch (on-demand)
    // engine never starts its render loop (only launch-born engines render — a
    // spike confirmed this), so build it now and keep it hidden at alpha 0 (engine
    // stays warm), revealed by "Open Image…". Mirrors this window's warm pattern.
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
    NSApp.setActivationPolicy(editorVisible || settingsVisible ? .regular : .accessory)
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
      result(register(actionKey: id, keyCode: UInt32(keyCode), modifiers: UInt32(modifiers)))
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
    channel.invokeMethod("onHotkey", arguments: actionKey)
  }

  private func register(actionKey: String, keyCode: UInt32, modifiers: UInt32) -> Bool {
    ensureHandler()
    unregister(actionKey: actionKey) // replace any existing binding for this action
    let id = nextId
    nextId += 1
    let hotKeyID = EventHotKeyID(signature: OSType(0x474C_4D52 /* 'GLMR' */), id: id)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    if status == noErr, let ref = ref {
      refs[actionKey] = ref
      actionForId[id] = actionKey
      return true
    }
    return false
  }

  private func unregister(actionKey: String) {
    if let ref = refs.removeValue(forKey: actionKey) {
      UnregisterEventHotKey(ref)
      actionForId = actionForId.filter { $0.value != actionKey }
    }
  }

  private func unregisterAll() {
    for (_, ref) in refs { UnregisterEventHotKey(ref) }
    refs.removeAll()
    actionForId.removeAll()
  }
}
