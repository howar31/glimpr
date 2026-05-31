import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var captureChannel: CaptureChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    captureChannel = CaptureChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
