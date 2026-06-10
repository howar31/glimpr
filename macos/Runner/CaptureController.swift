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
  func captureFrames(showsCursor: Bool) async throws -> [[String: Any]] {
    guard capturer.hasPermissionOrRequest() else {
      throw ScreenCapturer.CaptureError.noDisplays
    }
    // Direct modes bake the cursor (atomic capture) per the setting; no separate
    // cursor image (that is the overlay's toggleable path). Interim shim until
    // the native single-target captureRegion replaces this path entirely:
    // gather the per-display pushes back into the old batch shape.
    final class Box { var frames: [[String: Any]] = [] }
    let box = Box()
    try await capturer.captureAll(
      showsCursor: showsCursor, includeCursorImage: false
    ) { dict in
      box.frames.append(dict)
    }
    return box.frames
  }

  /// Capture a single window with real alpha (rounded corners), or nil when no
  /// such window — for the direct "Capture Window" mode and the overlay snap mask.
  func captureWindowImage(windowID: CGWindowID, showsCursor: Bool) async throws -> [String: Any]? {
    guard capturer.hasPermissionOrRequest() else {
      throw ScreenCapturer.CaptureError.noDisplays
    }
    return try await ScreenCapturer.captureWindowImage(
      windowID: windowID, showsCursor: showsCursor)
  }

  /// [pinOnly]: the ⌘⌥7 "capture to pin" mode — the overlay session runs as
  /// usual, but its confirm executes ONLY the pin action instead of the
  /// configured after-capture flow. Carried to the overlay engines via the
  /// onCaptureReady payload.
  func triggerCapture(pinOnly: Bool = false) {
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
        guard let manager = self.manager() else {
          Self.alert("Overlay manager not ready"); return
        }
        // Seed the presentation bookkeeping (key display + pendingShow) BEFORE
        // the parallel capture so per-display pushes land on clean state.
        manager.presentBegin(cursorDisplayID: self.capturer.cursorDisplayID())
        // Overlay: clean base (cursor is the toggleable layer) + the OS cursor
        // image for that toggle. Each display is pushed (and its engine starts
        // painting) the moment its capture is ready — cursor display first.
        PerfLog.mark("captureAllBegin")
        try await self.capturer.captureAll(
          showsCursor: false, includeCursorImage: true
        ) { dict in
          manager.presentFrame(dict, pinOnly: pinOnly)
        }
        PerfLog.mark("captureAllEnd")
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
