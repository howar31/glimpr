import Cocoa
import FlutterMacOS
import ScreenCaptureKit
import CoreGraphics

/// Temporary debug file logger (survives stdout buffering, works across engines).
func glog(_ s: String) {
  let line = "[swift] \(s)\n"
  let path = "/tmp/glimpr-debug.log"
  if !FileManager.default.fileExists(atPath: path) {
    FileManager.default.createFile(atPath: path, contents: nil)
  }
  if let h = FileHandle(forWritingAtPath: path) {
    h.seekToEndOfFile()
    if let d = line.data(using: .utf8) { h.write(d) }
    try? h.close()
  }
}

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
    // RENDER TEST: a plain titled, opaque, normal-level window (like the debug
    // window) to isolate whether the borderless/transparent/shielding-level
    // config is what stops Flutter from painting. If the red test screen shows
    // in THIS window, the overlay window config is the culprit; restore + add
    // properties back one at a time.
    super.init(contentRect: screen.visibleFrame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    isOpaque = true
    backgroundColor = .black
    isReleasedWhenClosed = false
    setFrame(screen.visibleFrame, display: false)
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
    let vc: FlutterViewController        // attached to the window only at show()
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
        default: result(FlutterMethodNotImplemented)
        }
      }
      let overlay = FlutterMethodChannel(name: "glimpr/overlay", binaryMessenger: msgr)

      let window = OverlayWindow(screen: screen)
      window.backgroundColor = .clear
      // Attach the view controller + reveal together in show() (renders on the
      // window's first appearance). Hidden until then.
      window.orderOut(nil)

      units[id] = Unit(window: window, engine: vc.engine, vc: vc, overlay: overlay, role: role, control: control)
    }
    glog("buildUnits done: \(units.count) unit(s) for displays \(Array(units.keys))")
  }

  private func rebuildIfIdle() {
    guard pendingShow.isEmpty else { return }
    for (_, u) in units { u.window.orderOut(nil); u.window.contentViewController = nil }
    units.values.forEach { $0.engine.shutDownEngine() }
    units.removeAll()
    buildUnits()
  }

  /// Distribute captured frames to their displays' engines. Each window is shown
  /// later, in show(displayID:), after its Dart signals overlayReady.
  func presentFrames(_ frames: [[String: Any]]) {
    // TEMP RENDER TEST: ignore frames; just attach + show every overlay window
    // so we can see whether the VC-owns-engine OverlayApp paints (red screen).
    glog("presentFrames RENDER TEST: showing \(units.count) units directly")
    for (id, _) in units { show(displayID: id) }
  }

  /// Capture-then-show: order front only AFTER the engine's Dart signals ready.
  private func show(displayID id: CGDirectDisplayID) {
    glog("show(\(id)) unit=\(units[id] != nil)")
    guard let unit = units[id] else { return }
    // Attach the view controller AND bring the window on-screen together: this
    // fires viewWillAppear/reshape so the FlutterView creates its surface and
    // paints the (already-built) frozen frame on its first render.
    if unit.window.contentViewController == nil {
      unit.window.contentViewController = unit.vc
    }
    NSApp.activate(ignoringOtherApps: true)
    if unit.window.canBecomeKey { unit.window.makeKeyAndOrderFront(nil) }
    unit.window.orderFrontRegardless()
    pendingShow.remove(id)
  }

  /// Esc-cancel or capture-fire: hide all windows atomically. Frozen buffers are
  /// local to capture() and released by ARC; the Dart side drops its references.
  func dismiss() {
    pendingShow.removeAll()
    // Detach the view and hide the window. The next capture re-attaches in
    // show(), which re-triggers viewWillAppear/reshape and a fresh render.
    for (_, u) in units {
      u.window.orderOut(nil)
      u.window.contentViewController = nil
    }
  }
}
