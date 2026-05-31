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
    SCShareableContent.getWithCompletionHandler { content, _ in self.cachedContent = content }
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
    let content: SCShareableContent
    if let cached = cachedContent { content = cached }
    else { content = try await SCShareableContent.current }
    cachedContent = content
    let displays = content.displays
    if displays.isEmpty { throw CaptureError.noDisplays }

    let cursor = NSEvent.mouseLocation
    var out: [[String: Any]] = []
    for d in displays {
      let scale = Self.scaleFactor(for: d.displayID)
      let cfg = SCStreamConfiguration()
      cfg.width = Int(CGFloat(d.width) * scale)
      cfg.height = Int(CGFloat(d.height) * scale)
      cfg.showsCursor = false
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
    super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    isMovableByWindowBackground = false
    isReleasedWhenClosed = false            // we orderOut, never close
    displaysWhenScreenProfileChanges = true
    sharingType = .none
    ignoresMouseEvents = false              // clicks/drags reach the FlutterView
    // Above the menu bar, Dock, and screen saver.
    level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    setFrame(screen.frame, display: false)
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
    let overlay: FlutterMethodChannel   // native -> Dart (onCaptureReady)
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
      // One pre-warmed headless engine per display, running the overlayMain entrypoint.
      let engine = FlutterEngine(name: "glimpr.overlay.\(id)", project: nil, allowHeadlessExecution: true)
      engine.run(withEntrypoint: "overlayMain")
      RegisterGeneratedPlugins(registry: engine)

      // Dart -> native control for this overlay engine.
      let control = FlutterMethodChannel(name: "glimpr/capture", binaryMessenger: engine.binaryMessenger)
      control.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "overlayReady": self?.show(displayID: id); result(nil)
        case "dismissOverlay": self?.dismiss(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
      let overlay = FlutterMethodChannel(name: "glimpr/overlay", binaryMessenger: engine.binaryMessenger)

      let vc = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
      vc.backgroundColor = NSColor.clear      // dual clear (with the window) for transparency

      let window = OverlayWindow(screen: screen)
      window.contentViewController = vc        // FlutterView is the contentView -> receives input
      window.backgroundColor = .clear
      window.orderOut(nil)                     // resident + hidden

      units[id] = Unit(window: window, engine: engine, overlay: overlay)
    }
  }

  private func rebuildIfIdle() {
    guard pendingShow.isEmpty else { return }
    for (_, u) in units { u.window.orderOut(nil) }
    units.values.forEach { $0.engine.shutDownEngine() }
    units.removeAll()
    buildUnits()
  }

  /// Distribute captured frames to their displays' engines. Each window is shown
  /// later, in show(displayID:), after its Dart signals overlayReady.
  func presentFrames(_ frames: [[String: Any]]) {
    pendingShow.removeAll()
    for frame in frames {
      guard let idInt = frame["displayId"] as? Int else { continue }
      let id = CGDirectDisplayID(idInt)
      guard let unit = units[id] else { continue }
      pendingShow.insert(id)
      unit.overlay.invokeMethod("onCaptureReady", arguments: ["display": frame])
    }
  }

  /// Capture-then-show: order front only AFTER the engine's Dart signals ready.
  private func show(displayID id: CGDirectDisplayID) {
    guard let unit = units[id] else { return }
    NSApp.activate(ignoringOtherApps: true)
    if unit.window.canBecomeKey { unit.window.makeKeyAndOrderFront(nil) }
    unit.window.orderFrontRegardless()
    pendingShow.remove(id)
  }

  /// Esc-cancel or capture-fire: hide all windows atomically. Frozen buffers are
  /// local to capture() and released by ARC; the Dart side drops its references.
  func dismiss() {
    pendingShow.removeAll()
    for (_, u) in units { u.window.orderOut(nil) }
  }
}
