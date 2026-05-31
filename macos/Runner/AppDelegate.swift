import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Pre-warmed per-display overlay windows + engines (created at launch).
  var overlayManager: OverlayManager?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    let manager = OverlayManager()
    manager.startObservingScreens()
    overlayManager = manager
  }

  // Resident app: hiding the overlay windows must NOT quit it.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
