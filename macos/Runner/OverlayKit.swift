import Cocoa
import FlutterMacOS
import ScreenCaptureKit
import CoreGraphics

// MARK: - ScreenCapturer

/// SCK capture of all displays using a cached SCShareableContent (enumeration
/// kept off the hot path — design §5). Returns one dictionary per display,
/// keyed exactly as the Dart `CapturedDisplay.fromMap` expects.
final class ScreenCapturer {
  private var cachedContent: SCShareableContent?

  init() {
    refreshCache()
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main) { [weak self] _ in self?.refreshCache() }
  }

  func refreshCache() {
    // Only adopt a refresh that actually has displays — a transient empty/error
    // result during a display reconfiguration must not clobber a good cache.
    SCShareableContent.getWithCompletionHandler { content, _ in
      if let content = content, !content.displays.isEmpty {
        self.cachedContent = content
      }
    }
  }

  /// true when Screen Recording (TCC) is granted; otherwise prompts and returns false.
  func hasPermissionOrRequest() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    CGRequestScreenCaptureAccess()
    return false
  }

  enum CaptureError: Error { case noDisplays }

  /// Captures every display. Throws CaptureError.noDisplays or rethrows SCK errors.
  func captureAll() async throws -> [[String: Any]] {
    // Trust the cache only while it still has displays; otherwise refetch fresh
    // (the cache can go stale/empty across a display add/remove).
    var shareable = cachedContent
    if shareable == nil || shareable!.displays.isEmpty {
      shareable = try await SCShareableContent.current
      cachedContent = shareable
    }
    guard let content = shareable, !content.displays.isEmpty else {
      throw CaptureError.noDisplays
    }
    let displays = content.displays

    let cursor = NSEvent.mouseLocation
    var out: [[String: Any]] = []
    for d in displays {
      let scale = Self.scaleFactor(for: d.displayID)
      let cfg = SCStreamConfiguration()
      cfg.width = Int(CGFloat(d.width) * scale)
      cfg.height = Int(CGFloat(d.height) * scale)
      cfg.showsCursor = false
      // Capture in sRGB. SCK otherwise tags frames with the display's native
      // wide-gamut profile (e.g. "LG ULTRAFINE"), but Flutter's Image widget
      // ignores embedded ICC profiles and treats pixels as sRGB — so a wide-
      // gamut frame renders with a visible color cast in the overlay. Producing
      // sRGB pixels makes the overlay match the live screen (the compositor
      // maps sRGB -> display), and saved PNGs become portable sRGB files.
      cfg.colorSpaceName = CGColorSpace.sRGB
      let filter = SCContentFilter(display: d, excludingWindows: [])
      let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
      guard let png = Self.pngData(from: cgImage) else { continue }
      let frame = d.frame
      let inDisplay = NSPointInRect(NSPoint(x: cursor.x, y: cursor.y), Self.flipToBottomLeft(frame))
      out.append([
        "displayId": Int(d.displayID),
        "pngBytes": FlutterStandardTypedData(bytes: png),
        "left": Double(frame.origin.x), "top": Double(frame.origin.y),
        "width": Double(frame.size.width), "height": Double(frame.size.height),
        "scaleFactor": Double(scale), "isCursorDisplay": inDisplay,
      ])
    }
    return out
  }

  static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
    for screen in NSScreen.screens {
      if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
         num.uint32Value == displayID { return screen.backingScaleFactor }
    }
    return 1.0
  }

  static func flipToBottomLeft(_ frame: CGRect) -> NSRect {
    let total = NSScreen.screens.map { $0.frame.maxY }.max() ?? frame.maxY
    return NSRect(x: frame.origin.x, y: total - frame.origin.y - frame.size.height,
                  width: frame.size.width, height: frame.size.height)
  }

  static func pngData(from cgImage: CGImage) -> Data? {
    NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
  }
}

// MARK: - OverlayWindow

/// A frameless, transparent, above-the-menu-bar overlay window pinned to one
/// NSScreen. One instance per display (a single window cannot span displays
/// when "Displays have separate Spaces" is ON — the macOS default).
final class OverlayWindow: NSWindow {
  // Borderless windows are not key/main by default; without these overrides,
  // keyboard events (Esc, future arrow-nudge) never arrive.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  init(screen: NSScreen) {
    // Borderless, transparent, above-everything overlay covering the FULL
    // display (screen.frame, not visibleFrame, so it covers the menu bar +
    // Dock). The frozen image + marquee are drawn by the Flutter view.
    super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
  }
}

// MARK: - OverlayManager

/// Owns the per-display overlay window + pre-warmed FlutterEngine set and the
/// capture-then-show / dismiss lifecycle. Resident: built once at launch and
/// reused (design §5/§18 — never recreated per capture).
final class OverlayManager {
  private struct Unit {
    let window: OverlayWindow
    let engine: FlutterEngine
    let vc: FlutterViewController        // attached + warmed on-screen at buildUnits
    let overlay: FlutterMethodChannel   // native -> Dart (onCaptureReady)
    let role: FlutterMethodChannel      // retained: native -> Dart role handler
    let control: FlutterMethodChannel   // retained: Dart -> native control handler
  }
  private var units: [CGDirectDisplayID: Unit] = [:]
  private var pendingShow: Set<CGDirectDisplayID> = []

  init() { buildUnits() }

  /// Rebuild the window/engine set on display hot-plug (idle only — design §17
  /// freezes topology during an active overlay).
  func startObservingScreens() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main) { [weak self] _ in self?.rebuildIfIdle() }
  }

  private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }

  private func buildUnits() {
    for screen in NSScreen.screens {
      let id = displayID(of: screen)
      // VC-owns-its-implicit-engine — the only pattern that renders reliably for
      // our windows on macOS (separate FlutterEngine().run() views never paint).
      // The implicit engine runs main(); a per-engine glimpr/role channel tells
      // Dart to show the OverlayApp rather than the debug control.
      let vc = FlutterViewController()
      RegisterGeneratedPlugins(registry: vc)
      vc.backgroundColor = NSColor.clear
      let msgr = vc.engine.binaryMessenger

      let role = FlutterMethodChannel(name: "glimpr/role", binaryMessenger: msgr)
      role.setMethodCallHandler { call, result in
        if call.method == "getRole" { result("overlay") } else { result(FlutterMethodNotImplemented) }
      }
      let control = FlutterMethodChannel(name: "glimpr/capture", binaryMessenger: msgr)
      control.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "overlayReady": self?.show(displayID: id); result(nil)
        case "dismissOverlay": self?.dismiss(); result(nil)
        case "warpCursor":
          if let a = call.arguments as? [String: Any],
             let x = a["x"] as? Double, let y = a["y"] as? Double {
            // Global top-left-origin display point. Re-associate so the mouse
            // keeps tracking after the warp (no permanent decoupling).
            CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
            CGAssociateMouseAndMouseCursorPosition(1)
          }
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
      let overlay = FlutterMethodChannel(name: "glimpr/overlay", binaryMessenger: msgr)

      let window = OverlayWindow(screen: screen)
      // Warm the engine NOW: a FlutterView only realizes its Metal surface and
      // runs its implicit engine's main() once its view enters an on-screen
      // window via a real (non-zero, display:true) layout pass — viewWillAppear
      // -> launchEngine, viewDidMoveToWindow -> CVDisplayLink, setFrameSize ->
      // viewDidReshape (verified against Flutter 3.44.0 engine source). So we
      // attach + size + order front ONCE at launch, then make the window
      // invisible (alpha 0) and click-through until a capture reveals it. This
      // is what makes secondary windows paint; orderOut/hidden-first does not.
      window.contentViewController = vc
      window.setFrame(screen.frame, display: true)
      window.orderFrontRegardless()
      window.alphaValue = 0
      window.ignoresMouseEvents = true

      units[id] = Unit(window: window, engine: vc.engine, vc: vc, overlay: overlay, role: role, control: control)
    }
  }

  private func rebuildIfIdle() {
    guard pendingShow.isEmpty else { return }
    for (_, u) in units { u.window.orderOut(nil); u.window.contentViewController = nil }
    units.values.forEach { $0.engine.shutDownEngine() }
    units.removeAll()
    buildUnits()
  }

  /// Distribute captured frames to their displays' engines. Each window is
  /// revealed later, in show(displayID:), after its Dart paints the frame and
  /// signals overlayReady — capture-then-show, no blank flash.
  func presentFrames(_ frames: [[String: Any]]) {
    pendingShow.removeAll()
    for f in frames {
      guard let raw = f["displayId"] as? Int else { continue }
      let id = CGDirectDisplayID(raw)
      guard let unit = units[id] else { continue }
      pendingShow.insert(id)
      unit.overlay.invokeMethod("onCaptureReady", arguments: ["display": f])
    }
  }

  /// Capture-then-show: the window is already on-screen + warm (alpha 0). Once
  /// Dart has painted the frozen frame and signalled overlayReady, reveal it.
  /// The setFrame(display:true) nudge forces a fresh reshape so the just-set
  /// frame is rasterized (also sidesteps the documented blank-on-reshow bug).
  private func show(displayID id: CGDirectDisplayID) {
    guard let unit = units[id] else { return }
    unit.window.setFrame(unit.window.screen?.frame ?? unit.window.frame, display: true)
    unit.window.ignoresMouseEvents = false
    unit.window.alphaValue = 1
    NSApp.activate(ignoringOtherApps: true)
    if unit.window.canBecomeKey { unit.window.makeKeyAndOrderFront(nil) }
    unit.window.orderFrontRegardless()
    pendingShow.remove(id)
  }

  /// Esc-cancel or capture-fire: hide all windows atomically. Windows stay
  /// resident on-screen (alpha 0, click-through) so their engines stay warm and
  /// the next capture re-reveals instantly — never orderOut, which would drop
  /// the view off-screen and risk a blank re-show.
  func dismiss() {
    pendingShow.removeAll()
    for (_, u) in units {
      u.window.alphaValue = 0
      u.window.ignoresMouseEvents = true
    }
  }
}
