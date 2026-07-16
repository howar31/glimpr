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
  /// `openURLs` Apple event. A .gif routes to the GIF editor; any other image
  /// opens in the Image Editor (via MainFlutterWindow, which buffers the path
  /// on a cold start until Dart is ready). Other URLs go to Flutter plugins.
  override func application(_ application: NSApplication, open urls: [URL]) {
    let imageURL = urls.first { url in
      guard url.isFileURL,
        let type = UTType(filenameExtension: url.pathExtension)
      else { return false }
      return type.conforms(to: .image)
    }
    if let url = imageURL {
      if url.pathExtension.lowercased() == "gif" {
        MainFlutterWindow.shared?.openGifEditorWithPath(url.path)
      } else {
        MainFlutterWindow.shared?.openImageFromExternal(url.path)
      }
    }
    super.application(application, open: urls)
  }
}
