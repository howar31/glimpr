import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var captureChannel: CaptureChannel?
  private var captureController: CaptureController?
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
      if call.method == "getRole" { result("debug") } else { result(FlutterMethodNotImplemented) }
    }
    self.roleChannel = roleChannel

    super.awakeFromNib()

    // Build + warm the per-display overlay windows/engines now (applicationDid-
    // FinishLaunching isn't reliably called in this nib setup). Each unit warms
    // its engine on-screen at alpha 0; a capture reveals the matching window.
    let manager = OverlayManager()
    manager.startObservingScreens()
    self.overlayManager = manager
  }
}
