import Cocoa
import ScreenCaptureKit

/// The native capture trigger, callable from both the Dart hotkey path
/// (CaptureChannel.beginCapture) and the menu-bar "Capture" item. Capture +
/// overlay presentation are pure native; failures surface via NSAlert.
final class CaptureController {
  private let capturer = ScreenCapturer()
  private let manager: () -> OverlayManager?

  init(manager: @escaping () -> OverlayManager?) { self.manager = manager }

  /// Single-target native capture for the direct (non-interactive) modes:
  /// cursor display when [displayID] is nil, cropped to [rect] when given,
  /// encoded natively to the final output format. nil when the requested
  /// display is gone. The cursor is baked per the setting (atomic capture; no
  /// separate cursor image — that is the overlay's toggleable path).
  func captureRegion(
    displayID: CGDirectDisplayID?, rect: CGRect?, showsCursor: Bool,
    jpeg: Bool, jpegQuality: Int, decoration: Decoration.Spec? = nil,
    alsoPlain: Bool = false
  ) async throws -> [String: Any]? {
    guard capturer.hasPermissionOrRequest() else {
      throw ScreenCapturer.CaptureError.noDisplays
    }
    return try await capturer.captureRegion(
      displayID: displayID, rect: rect, showsCursor: showsCursor,
      jpeg: jpeg, jpegQuality: jpegQuality, decoration: decoration,
      alsoPlain: alsoPlain)
  }

  /// Single window's raw alpha shape (rounded corners) — the overlay snap mask;
  /// nil when no such window. Used as a dstIn mask, so only the alpha matters.
  func captureWindowImage(windowID: CGWindowID, showsCursor: Bool) async throws -> [String: Any]? {
    guard capturer.hasPermissionOrRequest() else {
      throw ScreenCapturer.CaptureError.noDisplays
    }
    return try await ScreenCapturer.captureWindowImage(
      windowID: windowID, showsCursor: showsCursor)
  }

  /// Direct "Capture Window" — the FINAL encoded bytes (optionally decorated
  /// natively); nil when no such window so the caller falls back to a rect crop.
  func captureWindowDelivered(
    windowID: CGWindowID, showsCursor: Bool, jpeg: Bool, jpegQuality: Int,
    decoration: Decoration.Spec?, alsoPlain: Bool = false
  ) async throws -> [String: Any]? {
    guard capturer.hasPermissionOrRequest() else {
      throw ScreenCapturer.CaptureError.noDisplays
    }
    return try await ScreenCapturer.captureWindowDelivered(
      windowID: windowID, showsCursor: showsCursor, jpeg: jpeg,
      jpegQuality: jpegQuality, decoration: decoration, alsoPlain: alsoPlain)
  }

  /// [pinOnly]: the ⌘⌥7 "capture to pin" mode — the overlay session runs as
  /// usual, but its confirm executes ONLY the pin action instead of the
  /// configured after-capture flow. [liveSelect]: a RECORDING live-select
  /// session — no capture at all; the overlay presents transparent over the
  /// live screen and its confirm starts a recording. Both carried to the
  /// overlay engines via the onCaptureReady payload.
  func triggerCapture(pinOnly: Bool = false, liveSelect: Bool = false) {
    // Whole body on the main actor: NSAlert + the AppKit overlay work are all
    // MainActor-isolated, and triggerCapture() itself stays nonisolated so it is
    // callable from the method-channel handler and the menu action alike.
    Task { @MainActor in
      guard self.capturer.hasPermissionOrRequest() else {
        Self.alert(L.s(
          "Screen Recording permission is required. Enable it in System Settings "
            + "> Privacy & Security > Screen Recording, then relaunch.",
          "需要「螢幕錄製」權限。請在「系統設定 > 隱私權與安全性 > 螢幕錄製」"
            + "中啟用後重新啟動 Glimpr。"))
        return
      }
      // Safety net: a warm overlay unit for every CURRENT display before capture.
      self.manager()?.syncUnitsToScreens()
      guard let manager = self.manager() else {
        Self.alert(L.s("Overlay manager not ready", "覆疊管理器尚未就緒")); return
      }
      // A live-select session and a freeze session must not stack onto each
      // other (a transparent layer in a frozen stack corrupts both); ignore
      // the trigger while the other kind is up.
      if manager.liveSelectActive { return }
      if liveSelect {
        // No capture: geometry-only dicts, presented instantly.
        manager.presentBegin(cursorDisplayID: self.capturer.cursorDisplayID())
        for dict in ScreenCapturer.liveSelectGeometry() {
          manager.presentFrame(dict, liveSelect: true)
        }
        manager.beginLiveSelect()
        PerfLog.mark("liveSelectPresented")
        return
      }
      do {
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
        Self.alert(L.s("No displays found", "找不到螢幕"))
      } catch {
        Self.alert(L.s("Capture failed: ", "截圖失敗：") + "\(error)")
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
