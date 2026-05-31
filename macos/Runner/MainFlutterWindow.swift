import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var captureChannel: CaptureChannel?
  private var roleChannel: FlutterMethodChannel?
  var overlayManager: OverlayManager?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    captureChannel = CaptureChannel(
      messenger: flutterViewController.engine.binaryMessenger,
      manager: { [weak self] in self?.overlayManager }
    )

    // This window is the debug control; tell its Dart GlimprRoot which role to show.
    let roleChannel = FlutterMethodChannel(
      name: "glimpr/role", binaryMessenger: flutterViewController.engine.binaryMessenger)
    roleChannel.setMethodCallHandler { call, result in
      if call.method == "getRole" { result("debug") } else { result(FlutterMethodNotImplemented) }
    }
    self.roleChannel = roleChannel

    // NOTE: separate per-display overlay windows (OverlayManager) do not render
    // on this macOS/Flutter combo. For now the overlay is shown inside THIS
    // window (single display). Multi-display overlay is a follow-up.

    super.awakeFromNib()
  }
}
