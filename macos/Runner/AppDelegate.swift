import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // NOTE: applicationDidFinishLaunching is not reliably invoked in this
  // nib-based setup, so the per-display overlay windows/engines are pre-warmed
  // in MainFlutterWindow.awakeFromNib instead. The resident-app override below
  // is kept here.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
