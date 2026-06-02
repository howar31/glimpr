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
    roleChannel.setMethodCallHandler { call, result in
      if call.method == "getRole" { result("control") } else { result(FlutterMethodNotImplemented) }
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
    self.styleMask = [.titled, .closable, .miniaturizable]
    self.title = "Glimpr Settings"
    self.setContentSize(NSSize(width: 480, height: 360))
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

  /// Show the settings window on the user's CURRENT Space, in front.
  func revealSettings() {
    alphaValue = 1
    ignoresMouseEvents = false
    center()
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  private func hideSettings() {
    // Stay ON-SCREEN at alpha 0 (engine must remain warm — never orderOut, which
    // would drop the view off-screen and risk a blank re-show). orderBack tucks it
    // behind everything; resignKey returns focus to the previous app.
    alphaValue = 0
    ignoresMouseEvents = true
    orderBack(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideSettings()
    return false
  }
}
