import Cocoa
import FlutterMacOS

/// Registered on the DEBUG window's engine. Triggers the overlay capture flow
/// and serves the legacy `captureAllDisplays` pull. Capture is delegated to a
/// shared ScreenCapturer; window/engine lifecycle to the OverlayManager,
/// resolved LAZILY from the AppDelegate (this channel is built during nib load,
/// before applicationDidFinishLaunching creates the manager).
final class CaptureChannel {
  private let channel: FlutterMethodChannel
  private let overlay: FlutterMethodChannel
  private let capturer = ScreenCapturer()
  private let manager: () -> OverlayManager?

  init(messenger: FlutterBinaryMessenger, manager: @escaping () -> OverlayManager?) {
    self.manager = manager
    channel = FlutterMethodChannel(name: "glimpr/capture", binaryMessenger: messenger)
    overlay = FlutterMethodChannel(name: "glimpr/overlay", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "captureAllDisplays": self.captureAllDisplays(result: result)
      case "beginCapture": self.beginCapture(); result(nil)
      case "dismissOverlay": self.manager()?.dismiss(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Trigger the overlay: capture all displays, then hand the frames to the
  /// manager to distribute + show. Failures are reported to the debug window.
  private func beginCapture() {
    glog("beginCapture; managerFound=\(manager() != nil)")
    guard capturer.hasPermissionOrRequest() else {
      glog("beginCapture: permission denied")
      overlay.invokeMethod("onCaptureFailed", arguments: [
        "reason": "permissionDenied",
        "message": "Screen Recording permission is required. Enable it in System Settings > Privacy & Security > Screen Recording, then relaunch.",
      ])
      return
    }
    Task { @MainActor in
      do {
        let frames = try await self.capturer.captureAll()
        glog("captured \(frames.count) frame(s)")
        // Single-window overlay (proven render path): show the cursor display's
        // frozen frame in THIS window via onCaptureReady.
        let cursor = frames.first(where: { ($0["isCursorDisplay"] as? Bool) == true }) ?? frames.first
        if let f = cursor {
          self.overlay.invokeMethod("onCaptureReady", arguments: ["display": f])
        } else {
          self.overlay.invokeMethod("onCaptureFailed", arguments: ["reason": "noDisplays", "message": "No displays found"])
        }
      } catch ScreenCapturer.CaptureError.noDisplays {
        self.overlay.invokeMethod("onCaptureFailed", arguments: ["reason": "noDisplays", "message": "No displays found"])
      } catch {
        self.overlay.invokeMethod("onCaptureFailed", arguments: ["reason": "captureError", "message": "\(error)"])
      }
    }
  }

  /// Legacy Phase-1 pull (kept for existing tests / debug introspection).
  private func captureAllDisplays(result: @escaping FlutterResult) {
    guard capturer.hasPermissionOrRequest() else {
      result(FlutterError(code: "permissionDenied",
        message: "Screen Recording permission is required. Enable it in System Settings > Privacy & Security > Screen Recording, then relaunch.",
        details: nil))
      return
    }
    Task { @MainActor in
      do { result(try await self.capturer.captureAll()) }
      catch ScreenCapturer.CaptureError.noDisplays {
        result(FlutterError(code: "noDisplays", message: "No displays found", details: nil))
      } catch {
        result(FlutterError(code: "captureError", message: "\(error)", details: nil))
      }
    }
  }
}
