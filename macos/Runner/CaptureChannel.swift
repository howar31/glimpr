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
      case "beginCapture":
        let pinOnly =
          ((call.arguments as? [String: Any])?["pinOnly"] as? Bool) ?? false
        self?.capture.triggerCapture(pinOnly: pinOnly)
        result(nil)
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
      // After-capture flow: float the exported file as an always-on-top pin.
      case "pinImage":
        if let a = call.arguments as? [String: Any], let path = a["path"] as? String {
          let rect: CGRect?
          if let x = a["x"] as? Double, let y = a["y"] as? Double,
             let w = a["w"] as? Double, let h = a["h"] as? Double {
            rect = CGRect(x: x, y: y, width: w, height: h)
          } else {
            rect = nil
          }
          DispatchQueue.main.async {
            MainFlutterWindow.shared?.pinImage(path: path, rect: rect)
          }
        }
        result(nil)
      // A capture flow wrote the shared recent-images store: forward a refresh
      // to the editor engine (it owns the landing gallery + Open Recent menu).
      case "recentChanged":
        DispatchQueue.main.async {
          MainFlutterWindow.shared?.notifyRecentChanged()
        }
        result(nil)
      case "perfMark":
        if let label = (call.arguments as? [String: Any])?["label"] as? String {
          PerfLog.mark(label)
        }
        result(nil)
      case "captureRegion":
        // Main actor like triggerCapture: the capture reaches NSScreen and the
        // channel reply must land on the platform (main) thread.
        let a = call.arguments as? [String: Any]
        let displayId = (a?["displayId"] as? NSNumber)?.uint32Value
        let rect: CGRect?
        if let x = a?["x"] as? Double, let y = a?["y"] as? Double,
           let w = a?["w"] as? Double, let h = a?["h"] as? Double {
          rect = CGRect(x: x, y: y, width: w, height: h)
        } else {
          rect = nil
        }
        let cursor = (a?["showsCursor"] as? Bool) ?? false
        let jpeg = (a?["jpeg"] as? Bool) ?? false
        let quality = (a?["quality"] as? Int) ?? 90
        Task { @MainActor in
          do {
            let res = try await self?.capture.captureRegion(
              displayID: displayId.map { CGDirectDisplayID($0) }, rect: rect,
              showsCursor: cursor, jpeg: jpeg, jpegQuality: quality)
            result(res) // nil -> Dart picks the fallback (display gone)
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
