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
      case "captureFrames":
        Task {
          do {
            let frames = try await self?.capture.captureFrames() ?? []
            result(frames)
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
