import Cocoa
import FlutterMacOS

/// Registered on the control window's engine. Bridges the Dart hotkey to the
/// native capture trigger. Capture logic lives in CaptureController; window/
/// engine lifecycle in OverlayManager.
final class CaptureChannel {
  private let channel: FlutterMethodChannel
  private let capture: CaptureController
  private let manager: () -> OverlayManager?

  init(
    messenger: FlutterBinaryMessenger,
    capture: CaptureController,
    manager: @escaping () -> OverlayManager?
  ) {
    self.capture = capture
    self.manager = manager
    channel = FlutterMethodChannel(name: "glimpr/capture", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "beginCapture": self?.capture.triggerCapture(); result(nil)
      case "dismissOverlay": self?.manager()?.dismiss(); result(nil)
      // After-capture flow: open the just-exported file in the image editor.
      case "openInEditor":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          DispatchQueue.main.async {
            MainFlutterWindow.shared?.openImageFromExternal(path)
          }
        }
        result(nil)
      // After-capture flow: macOS share sheet for the exported file.
      case "shareSheet":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          DispatchQueue.main.async {
            MainFlutterWindow.shared?.showShareSheet(path: path)
          }
        }
        result(nil)
      case "captureFrames":
        // Main actor like triggerCapture: captureAll() reaches NSEvent/NSScreen
        // and the channel reply must land on the platform (main) thread.
        let cursor = ((call.arguments as? [String: Any])?["showsCursor"] as? Bool)
          ?? false
        Task { @MainActor in
          do {
            let frames = try await self?.capture.captureFrames(showsCursor: cursor) ?? []
            result(frames)
          } catch {
            result(FlutterError(
              code: "capture_failed", message: "\(error)", details: nil))
          }
        }
      case "focusedWindow":
        result(ScreenCapturer.focusedWindow())
      case "captureWindowImage":
        let a = call.arguments as? [String: Any]
        let wid = (a?["windowId"] as? NSNumber)?.uint32Value ?? 0
        let cursor = (a?["showsCursor"] as? Bool) ?? false
        Task { @MainActor in
          do {
            let img = try await self?.capture.captureWindowImage(
              windowID: CGWindowID(wid), showsCursor: cursor)
            result(img) // nil -> Dart treats as "no image" and falls back
          } catch {
            result(FlutterError(
              code: "capture_failed", message: "\(error)", details: nil))
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}
