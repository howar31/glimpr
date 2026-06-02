import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var captureChannel: CaptureChannel?
  private var captureController: CaptureController?
  private var statusItem: StatusItemController?
  private var roleChannel: FlutterMethodChannel?
  var overlayManager: OverlayManager?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let capture = CaptureController(manager: { [weak self] in self?.overlayManager })
    self.captureController = capture
    captureChannel = CaptureChannel(
      messenger: flutterViewController.engine.binaryMessenger,
      capture: capture,
      manager: { [weak self] in self?.overlayManager }
    )

    // This window is the debug control; tell its Dart GlimprRoot which role to show.
    let roleChannel = FlutterMethodChannel(
      name: "glimpr/role", binaryMessenger: flutterViewController.engine.binaryMessenger)
    roleChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getRole": result("control")
      // Cmd-W from the settings UI: hide the window (same as the close button).
      case "closeSettings": self?.hideSettings(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    self.roleChannel = roleChannel

    super.awakeFromNib()

    // Build + warm the per-display overlay windows/engines now (applicationDid-
    // FinishLaunching isn't reliably called in this nib setup). Each unit warms
    // its engine on-screen at alpha 0; a capture reveals the matching window.
    let manager = OverlayManager()
    manager.startObservingScreens()
    self.overlayManager = manager

    self.statusItem = StatusItemController(
      onCapture: { [weak self] in self?.captureController?.triggerCapture() },
      onSettings: { [weak self] in self?.revealSettings() })

    // Resident: keep the engine warm (on-screen, transparent, click-through) so
    // main() runs + the hotkey registers, but present nothing until "Settings…".
    // Fixed-size settings window (NOT .resizable) with an inline, transparent
    // title bar so the Flutter sidebar runs to the top edge behind the traffic
    // lights (macOS preferences style). The content lays out its own top inset.
    self.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    self.title = "Glimpr Settings"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.setContentSize(NSSize(width: 680, height: 480))
    // Fixed-size window: disable the green zoom / fullscreen button. This also
    // removes its window-tiling hover menu, whose modal tracking run loop blocked
    // the global capture hotkey (same-process Carbon hotkey) while it was open.
    // AppKit re-enables it on some events (e.g. regaining key after a capture),
    // so it is re-applied in revealSettings + windowDidUpdate.
    disableZoomButton()
    self.isReleasedWhenClosed = false
    self.collectionBehavior = [.moveToActiveSpace]
    self.delegate = self
    // Order front THEN drop alpha (the proven warm-engine order — same as the
    // overlay windows): an on-screen layout pass realizes the Metal surface and
    // runs main(), after which alpha 0 hides it without dropping it off-screen.
    self.orderFrontRegardless()
    self.alphaValue = 0
    self.ignoresMouseEvents = true
  }

  /// Show the settings window on the user's CURRENT Space, in front. While it is
  /// visible the app becomes a regular app (Dock icon + Cmd-Tab); it reverts to a
  /// menu-bar accessory when the window is closed (see hideSettings).
  func revealSettings() {
    NSApp.setActivationPolicy(.regular)
    alphaValue = 1
    ignoresMouseEvents = false
    center()
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    disableZoomButton()
  }

  private func hideSettings() {
    // Stay ON-SCREEN at alpha 0 (engine must remain warm — never orderOut, which
    // would drop the view off-screen and risk a blank re-show). orderBack tucks it
    // behind everything. Back to accessory: no Dock icon / not in Cmd-Tab at rest,
    // which also keeps the overlay's activate from switching Spaces during capture.
    alphaValue = 0
    ignoresMouseEvents = true
    orderBack(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideSettings()
    return false
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
}
