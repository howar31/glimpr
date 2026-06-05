import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

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

  /// Finder "Open With Glimpr" / double-click on a registered image type sends an
  /// `openURLs` Apple event. Open the first image file in the Image Editor (via
  /// MainFlutterWindow, which buffers the path on a cold start until Dart is
  /// ready). Other URLs are forwarded to Flutter plugins via super.
  override func application(_ application: NSApplication, open urls: [URL]) {
    let imagePath = urls.first { url in
      guard url.isFileURL,
        let type = UTType(filenameExtension: url.pathExtension)
      else { return false }
      return type.conforms(to: .image)
    }?.path
    if let path = imagePath {
      MainFlutterWindow.shared?.openImageFromExternal(path)
    }
    super.application(application, open: urls)
  }
}
