import Cocoa
import ScreenCaptureKit

/// The native capture trigger, callable from both the Dart hotkey path
/// (CaptureChannel.beginCapture) and the menu-bar "Capture" item. Capture +
/// overlay presentation are pure native; failures surface via NSAlert.
final class CaptureController {
  private let capturer = ScreenCapturer()
  private let manager: () -> OverlayManager?

  init(manager: @escaping () -> OverlayManager?) { self.manager = manager }

  /// Capture all displays and RETURN the frame dicts (no overlay) — for the
  /// direct (non-interactive) capture modes. Throws if permission is missing or
  /// there are no displays.
  func captureFrames() async throws -> [[String: Any]] {
    guard capturer.hasPermissionOrRequest() else {
      throw ScreenCapturer.CaptureError.noDisplays
    }
    return try await capturer.captureAll()
  }

  func triggerCapture() {
    // Whole body on the main actor: NSAlert + the AppKit overlay work are all
    // MainActor-isolated, and triggerCapture() itself stays nonisolated so it is
    // callable from the method-channel handler and the menu action alike.
    Task { @MainActor in
      guard self.capturer.hasPermissionOrRequest() else {
        Self.alert(
          "Screen Recording permission is required. Enable it in System Settings "
            + "> Privacy & Security > Screen Recording, then relaunch.")
        return
      }
      // Safety net: a warm overlay unit for every CURRENT display before capture.
      self.manager()?.syncUnitsToScreens()
      do {
        let frames = try await self.capturer.captureAll()
        guard let manager = self.manager() else {
          Self.alert("Overlay manager not ready"); return
        }
        manager.presentFrames(frames)
      } catch ScreenCapturer.CaptureError.noDisplays {
        Self.alert("No displays found")
      } catch {
        Self.alert("Capture failed: \(error)")
      }
    }
  }

  @MainActor private static func alert(_ message: String) {
    let a = NSAlert()
    a.messageText = "Glimpr"
    a.informativeText = message
    a.alertStyle = .warning
    a.runModal()
  }
}
