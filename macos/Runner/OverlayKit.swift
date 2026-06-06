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
    // Trust the cache only while its display SET still matches the current
    // screens; otherwise refetch fresh (the cache goes stale across a display
    // add/remove, which would drop a hot-plugged display from the capture).
    let currentIDs = Set(NSScreen.screens.compactMap { Self.screenNumber($0) })
    var shareable = cachedContent
    let cachedIDs = Set((shareable?.displays ?? []).map { $0.displayID })
    if shareable == nil || shareable!.displays.isEmpty || cachedIDs != currentIDs {
      shareable = try await SCShareableContent.current
      cachedContent = shareable
    }
    guard let content = shareable, !content.displays.isEmpty else {
      throw CaptureError.noDisplays
    }
    let displays = content.displays

    // Which display holds the cursor = the interactive editor display. Use
    // NSScreen: NSEvent.mouseLocation and NSScreen.frame share the same Cocoa
    // bottom-left global space, so NSMouseInRect needs NO coordinate flip (the
    // old CG/Cocoa flip mismapped multi-display layouts, landing the editor on
    // the wrong display). Fall back to the main, then the first, display so
    // EXACTLY ONE display is always the cursor display — never a no-editor freeze.
    let mouse = NSEvent.mouseLocation
    let cursorDisplayID: CGDirectDisplayID =
      NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        .flatMap(Self.screenNumber)
        ?? NSScreen.main.flatMap(Self.screenNumber)
        ?? displays.first!.displayID

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
      let isCursor = d.displayID == cursorDisplayID
      var dict: [String: Any] = [
        "displayId": Int(d.displayID),
        "pngBytes": FlutterStandardTypedData(bytes: png),
        "left": Double(frame.origin.x), "top": Double(frame.origin.y),
        "width": Double(frame.size.width), "height": Double(frame.size.height),
        "scaleFactor": Double(scale),
        "isCursorDisplay": isCursor,
      ]
      // Seed the crosshair at the real cursor (display-local, top-left origin)
      // instead of the display centre. Same Cocoa global -> local conversion as
      // setActiveDisplay (NSEvent.mouseLocation + NSScreen.frame, bottom-left).
      if isCursor,
         let s = NSScreen.screens.first(where: { Self.screenNumber($0) == d.displayID }) {
        dict["cursorX"] = Double(mouse.x - s.frame.minX)
        dict["cursorY"] = Double(s.frame.maxY - mouse.y)
      }
      dict["windows"] = Self.snappableWindows(displayID: d.displayID)
      out.append(dict)
    }
    return out
  }

  /// Capture a SINGLE window with its REAL alpha — the area outside the window's
  /// rounded-corner shape is transparent (a desktop-independent window filter
  /// composites only this window). Returns PNG bytes (alpha-preserving) + geometry,
  /// or nil if no SCWindow matches [windowID] so the caller falls back to a rect
  /// crop. Faithful to the OS-provided window shape (no assumed corner radius).
  // Static so BOTH the control engine (CaptureController) and EVERY overlay
  // engine (the snap mask) can call it — each Flutter engine has its own
  // `glimpr/capture` handler, so the overlay can't reach the control engine's.
  static func captureWindowImage(windowID: CGWindowID) async throws -> [String: Any]? {
    // Fetch shareable content fresh (window sets change between captures) and
    // find the target window.
    let shareable = try await SCShareableContent.current
    guard let window = shareable.windows.first(where: { $0.windowID == windowID })
    else { return nil }

    // Scale from the window's display (fallback: the main display).
    let scale = Self.displayForRect(window.frame).map(Self.scaleFactor(for:))
      ?? Self.scaleFactor(for: CGMainDisplayID())
    let cfg = SCStreamConfiguration()
    cfg.width = max(1, Int((window.frame.width * scale).rounded()))
    cfg.height = max(1, Int((window.frame.height * scale).rounded()))
    cfg.showsCursor = false
    cfg.colorSpaceName = CGColorSpace.sRGB
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let cg = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: cfg)
    guard let png = Self.pngData(from: cg) else { return nil }
    return [
      "pngBytes": FlutterStandardTypedData(bytes: png),
      "width": cfg.width,
      "height": cfg.height,
      "scale": Double(scale),
    ]
  }

  /// Snappable top-level windows on [displayID], as display-local logical rects
  /// [x, y, w, h] (top-left origin), front-to-back. Filters to snappable window
  /// levels — normal app windows (0), floating panels (3), and standalone modal
  /// alerts (8, e.g. the CoreServicesUIAgent "file can't be found" dialog) —
  /// excludes invisible windows, the menu bar/Dock/notification layer, tiny
  /// helpers, and clamps to the display. Window bounds/alpha/layer need no
  /// Screen-Recording permission. CGWindowBounds and CGDisplayBounds are both CG
  /// global top-left.
  /// NOTE: our OWN visible windows (settings, future editor windows) ARE
  /// snappable — the freeze overlay is already excluded because it lives above
  /// these levels (shielding level), and the warm control window is excluded by
  /// the alpha filter below, so there's no need to exclude our whole process.
  /// NOTE: notifications can't be snapped — their on-screen CGWindow is the
  /// full-screen Notification Center container (layer 21), not the banner rect,
  /// so admitting that level would only yield a whole-screen target.
  static func snappableWindows(displayID: CGDirectDisplayID) -> [[String: Any]] {
    let dispBounds = CGDisplayBounds(displayID)
    guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
      as? [[String: Any]] else { return [] }
    // Normal app windows (0), floating panels (kCGFloatingWindowLevel 3), and
    // standalone modal alerts (kCGModalPanelWindowLevel 8). Higher levels are
    // deliberately excluded: Dock (20), notifications (21), menu bar (24),
    // status items (25), pop-up menus (101), and our own freeze overlay.
    let snappableLevels: Set<Int> = [0, 3, 8]
    var out: [[String: Any]] = []
    for w in infos { // front-to-back
      guard let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
            snappableLevels.contains(layer) else { continue }
      // Skip effectively-invisible windows (e.g. our own warm control window at
      // alpha 0) so they don't become phantom snap targets.
      guard let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
            alpha > 0.05 else { continue }
      guard let b = w[kCGWindowBounds as String] as? [String: Any],
            let x = (b["X"] as? NSNumber)?.doubleValue,
            let y = (b["Y"] as? NSNumber)?.doubleValue,
            let ww = (b["Width"] as? NSNumber)?.doubleValue,
            let hh = (b["Height"] as? NSNumber)?.doubleValue else { continue }
      if ww < 40 || hh < 40 { continue }
      let r = CGRect(x: x, y: y, width: ww, height: hh)
      let inter = r.intersection(dispBounds)
      if inter.isNull || inter.width < 1 || inter.height < 1 { continue }
      // Window title (kCGWindowName needs Screen-Recording permission, which we
      // hold; can still be empty) + owning app name (always available) — used to
      // name the saved file after the window under the cursor at capture.
      let title = (w[kCGWindowName as String] as? String) ?? ""
      let app = (w[kCGWindowOwnerName as String] as? String) ?? ""
      out.append([
        "x": Double(inter.minX - dispBounds.minX),
        "y": Double(inter.minY - dispBounds.minY),
        "w": Double(inter.width),
        "h": Double(inter.height),
        "title": title,
        "app": app,
        "windowNumber": (w[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
      ])
    }
    return out
  }

  /// The display whose bounds overlap [r] the most, or nil. CGWindowBounds and
  /// CGDisplayBounds are both CG global top-left, so they compare directly.
  static func displayForRect(_ r: CGRect) -> CGDirectDisplayID? {
    var best: CGDirectDisplayID?
    var bestArea: CGFloat = 0
    for screen in NSScreen.screens {
      guard let id = screenNumber(screen) else { continue }
      let inter = r.intersection(CGDisplayBounds(id))
      let area = inter.isNull ? 0 : inter.width * inter.height
      if area > bestArea { bestArea = area; best = id }
    }
    return best
  }

  /// The frontmost FOCUSED window (frontmost app's front on-screen window) as a
  /// display-local logical rect, mirroring snappableWindows' mapping. Returns the
  /// dict { displayId, x, y, w, h, title, app } or nil if there is no such window.
  static func focusedWindow() -> [String: Any]? {
    guard let frontPid =
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
          let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    for w in infos { // front-to-back
      guard let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
            layer == 0,
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            owner == frontPid,
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
            alpha > 0.05,
            let b = w[kCGWindowBounds as String] as? [String: Any],
            let x = (b["X"] as? NSNumber)?.doubleValue,
            let y = (b["Y"] as? NSNumber)?.doubleValue,
            let ww = (b["Width"] as? NSNumber)?.doubleValue,
            let hh = (b["Height"] as? NSNumber)?.doubleValue
      else { continue }
      if ww < 40 || hh < 40 { continue }
      let r = CGRect(x: x, y: y, width: ww, height: hh)
      guard let displayID = displayForRect(r) else { continue }
      let dispBounds = CGDisplayBounds(displayID)
      let inter = r.intersection(dispBounds)
      if inter.isNull || inter.width < 1 || inter.height < 1 { continue }
      let title = (w[kCGWindowName as String] as? String) ?? ""
      let app = (w[kCGWindowOwnerName as String] as? String) ?? ""
      return [
        "displayId": Int(displayID),
        "x": Double(inter.minX - dispBounds.minX),
        "y": Double(inter.minY - dispBounds.minY),
        "w": Double(inter.width),
        "h": Double(inter.height),
        "title": title,
        "app": app,
        "windowNumber": (w[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
      ]
    }
    return nil
  }

  static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
    for screen in NSScreen.screens {
      if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
         num.uint32Value == displayID { return screen.backingScaleFactor }
    }
    return 1.0
  }

  /// CGDirectDisplayID for an NSScreen (its "NSScreenNumber" device key).
  static func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
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
    // Deliver mouse-moved (hover) events even while this window is NOT key, so
    // the editor can follow the cursor onto a not-yet-focused display without a
    // click first (a non-key window gets no mouseMoved by default).
    acceptsMouseMovedEvents = true
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
    let fonts: FlutterMethodChannel     // retained: system font families enumerator
  }
  private var units: [CGDirectDisplayID: Unit] = [:]
  private var pendingShow: Set<CGDirectDisplayID> = []
  // The display the cursor is on at capture = the interactive editor. Only its
  // window takes key/active focus on reveal (see show()). nil = unknown.
  private var keyDisplayID: CGDirectDisplayID?

  // Launch-born warm spares (see buildUnits): healthy, vsync-seeded engines parked
  // alpha-0, re-homed onto displays hot-plugged AFTER launch. A unit created fresh
  // on a just-attached display never starts its steady-state render loop, so we
  // move one of these instead. didBuildLaunchUnits gates the launch batch from
  // consuming spares; spareCount bounds how many post-launch displays are covered.
  private var spares: [Unit] = []
  private var didBuildLaunchUnits = false
  // Pre-warm enough launch-born engines that up to this many displays TOTAL can be
  // handled at once. Engines only initialize a working render loop at app launch,
  // so spares are pre-stocked = max(0, target - displays present at launch) and
  // re-homed onto displays hot-plugged later. Resident warm engines = max(displays-
  // at-launch, target), each ~100 MB. Displays beyond target degrade gracefully
  // (freeze shown, HUD follow needs a restart). User-tunable in Settings > Advanced
  // (persisted to UserDefaults by the role channel); read here ONCE at launch, so a
  // change applies on the next launch. Default 2; clamped 1...8 against a bad pref.
  private let maxTotalDisplays: Int = {
    let stored = UserDefaults.standard.object(forKey: "overlayWarmTarget") as? Int
    return max(1, min(8, stored ?? 2))
  }()

  // Single-authority cross-display follow: a high-frequency poll of the GLOBAL
  // cursor position decides which display is active (one source of truth),
  // instead of each engine guessing from its own key-window-gated mouse events
  // and handing off asynchronously (which raced -> flicker). Runs only while an
  // overlay session is on screen.
  private var cursorTimer: Timer?
  private var activeID: CGDirectDisplayID?
  // While a draw/crop drag is in progress this holds the drawing display. The
  // active handoff is frozen, and the cursor is confined to the display by
  // warping it back to the edge if it strays (coupled, so speed is unchanged;
  // the cursor is hidden + the rendered crosshair is clamped during the drag, so
  // the confinement is invisible and jitter-free). The confine runs on every
  // drag event (dragMonitor, tightest) plus the poll as a backup.
  private var drawingLockID: CGDirectDisplayID?
  private var dragMonitor: Any? // local NSEvent monitor confining on each drag
  // Owned system-cursor visibility: the active editor engine drives this (hide
  // over the canvas where we draw our own crosshair/reticle, show over the
  // toolbar). A single owned bool keeps NSCursor.hide/unhide balanced; always
  // restored on dismiss. NSCursor.hide is app-global, so it also covers the
  // instant the cursor strays onto another display mid-drag.
  private var cursorHidden = false

  deinit { if let m = dragMonitor { NSEvent.removeMonitor(m) } }

  init() { buildUnits() }

  /// Re-sync the window/engine set on display hot-plug (idle only — design §17
  /// freezes topology during an active overlay; a change missed here is caught
  /// by the safety-net sync before the next capture).
  func startObservingScreens() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main) { [weak self] _ in
        guard let self = self, self.pendingShow.isEmpty else { return }
        self.syncUnitsToScreens()
    }
  }

  private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }

  private func buildUnits() {
    for screen in NSScreen.screens { units[displayID(of: screen)] = makeUnit(on: screen) }
    // Launch-born spares: warm, vsync-seeded engines parked alpha-0 on a present
    // display, ready to be RE-HOMED onto a display hot-plugged AFTER launch. A unit
    // created fresh ON a just-attached display never starts its steady-state render
    // loop (its implicit engine's display snapshot races the new display's
    // enumeration and the fresh CVDisplayLink can be stillborn), so on hot-plug we
    // move one of these healthy launch-born units instead (see syncUnitsToScreens).
    let spareTarget = max(0, maxTotalDisplays - NSScreen.screens.count)
    if spareTarget > 0, let host = NSScreen.main ?? NSScreen.screens.first {
      for _ in 0..<spareTarget { spares.append(makeUnit(on: host)) }
    }
    didBuildLaunchUnits = true
  }

  /// Last-resort direct-create: build a unit FOR its own display and register it.
  /// A unit created directly on a freshly-attached display may never start its
  /// render loop (see makeUnit), so this is only used when there is no OTHER present
  /// display to host an on-demand unit on (see addUnitOnDemand).
  private func addUnit(for screen: NSScreen) {
    units[displayID(of: screen)] = makeUnit(on: screen)
  }

  /// Reverse-lookup: which display does this view controller currently serve? A
  /// unit's per-engine control handler resolves its display id dynamically (not
  /// captured at creation) so a parked spare can be re-homed onto any display.
  private func displayID(forVC vc: FlutterViewController) -> CGDirectDisplayID? {
    for (id, u) in units where u.vc === vc { return id }
    return nil
  }

  /// Build + warm ONE overlay window + implicit FlutterEngine on `screen` (resident
  /// at alpha 0). Does NOT register it in `units` — the caller decides whether it is
  /// a live display unit or a parked spare. The control handler resolves its display
  /// id via displayID(forVC:) at call time, so the same unit can later be re-homed.
  private func makeUnit(on screen: NSScreen) -> Unit {
      // VC-owns-its-implicit-engine — the only pattern that renders reliably for
      // our windows on macOS (separate FlutterEngine().run() views never paint).
      // The implicit engine runs main(); a per-engine glimpr/role channel tells
      // Dart to show the OverlayApp rather than the debug control.
      let vc = FlutterViewController()
      // Track mouse hover/enter/exit whenever the APP is active, not only when
      // THIS window is key (Flutter's default is .inKeyWindow). The editor
      // follows the cursor across displays via MouseRegion.onEnter -> makeKey;
      // with the default, a non-key display can't report the cursor until it has
      // already become key (an async round-trip), so a fast cross-display move
      // lagged or stalled. .inActiveApp lets every overlay's view fire enter/exit
      // immediately on cross, regardless of which window is currently key.
      vc.mouseTrackingMode = .inActiveApp
      RegisterGeneratedPlugins(registry: vc)
      vc.backgroundColor = NSColor.clear
      let msgr = vc.engine.binaryMessenger

      let role = FlutterMethodChannel(name: "glimpr/role", binaryMessenger: msgr)
      role.setMethodCallHandler { call, result in
        if call.method == "getRole" { result("overlay") } else { result(FlutterMethodNotImplemented) }
      }
      let control = FlutterMethodChannel(name: "glimpr/capture", binaryMessenger: msgr)
      control.setMethodCallHandler { [weak self, weak vc] call, result in
        guard let self = self else { result(nil); return }
        switch call.method {
        case "overlayReady":
          if let vc = vc, let id = self.displayID(forVC: vc) { self.show(displayID: id) }
          result(nil)
        case "broadcastEditorState":
          if let vc = vc, let id = self.displayID(forVC: vc),
             let a = call.arguments as? [String: Any] {
            self.broadcastEditorState(from: id, args: a)
          }
          result(nil)
        case "dismissOverlay": self.dismiss(); result(nil)
        case "showError":
          if let a = call.arguments as? [String: Any],
             let msg = a["message"] as? String {
            self.showError(msg)
          }
          result(nil)
        case "setDrawingLock":
          // Confine the cursor to THIS display while a draw/crop drag is in
          // progress, and freeze the active handoff so the stroke isn't wiped if
          // the pointer would otherwise wander onto another display.
          if let vc = vc, let id = self.displayID(forVC: vc),
             let a = call.arguments as? [String: Any],
             let locked = a["locked"] as? Bool {
            self.setDrawingLock(locked ? id : nil)
          }
          result(nil)
        case "setCursorHidden":
          if let a = call.arguments as? [String: Any],
             let hidden = a["hidden"] as? Bool {
            self.setCursorHidden(hidden)
          }
          result(nil)
        case "warpCursor":
          if let a = call.arguments as? [String: Any],
             let x = a["x"] as? Double, let y = a["y"] as? Double {
            // Global top-left-origin display point. Re-associate so the mouse
            // keeps tracking after the warp (no permanent decoupling).
            CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
            CGAssociateMouseAndMouseCursorPosition(1)
          }
          result(nil)
        case "captureWindowImage":
          // The overlay snap fetches the window's real alpha here (this engine
          // has its OWN glimpr/capture handler, separate from the control one).
          let wid = ((call.arguments as? [String: Any])?["windowId"] as? NSNumber)?
            .uint32Value ?? 0
          Task { @MainActor in
            do {
              let img = try await ScreenCapturer.captureWindowImage(
                windowID: CGWindowID(wid))
              result(img)
            } catch {
              result(FlutterError(
                code: "capture_failed", message: "\(error)", details: nil))
            }
          }
        default: result(FlutterMethodNotImplemented)
        }
      }
      let overlay = FlutterMethodChannel(name: "glimpr/overlay", binaryMessenger: msgr)

      let fonts = FlutterMethodChannel(name: "glimpr/fonts", binaryMessenger: msgr)
      fonts.setMethodCallHandler { call, result in
        if call.method == "availableFamilies" {
          result(NSFontManager.shared.availableFontFamilies.sorted())
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

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

      return Unit(window: window, engine: vc.engine, vc: vc, overlay: overlay, role: role, control: control, fonts: fonts)
  }

  /// Add/remove warm overlay units so there is exactly one per CURRENT display.
  /// Incremental — existing displays' units (and their warm engines) are left
  /// untouched; only a newly-attached display gets a fresh warm unit, and a
  /// detached display's unit is torn down. Run on display hot-plug AND as a
  /// safety net before each capture, so changing displays never leaves one
  /// without an overlay (which froze the capture).
  func syncUnitsToScreens() {
    let currentIDs = Set(NSScreen.screens.map { displayID(of: $0) })
    for id in Set(units.keys).subtracting(currentIDs) {
      let removed = units[id]
      units.removeValue(forKey: id)
      guard let u = removed else { continue }
      // Return the (launch-born, vsync-seeded) unit to the spare pool instead of
      // tearing it down, so docking/undocking keeps working: re-park it warm +
      // alpha-0 on a SURVIVING display (never orderOut, which nulls window.screen
      // and unregisters its Flutter display link). Keep only as many spares as the
      // target needs for the now-fewer displays; shut down any excess so the
      // resident warm-engine count stays bounded.
      let desiredSpares = max(0, maxTotalDisplays - units.count)
      if spares.count < desiredSpares, let host = NSScreen.main ?? NSScreen.screens.first {
        u.window.setFrame(host.frame, display: true)
        u.window.alphaValue = 0
        u.window.ignoresMouseEvents = true
        spares.append(u)
      } else {
        u.window.orderOut(nil)
        u.window.contentViewController = nil
        u.engine.shutDownEngine()
      }
    }
    for screen in NSScreen.screens where units[displayID(of: screen)] == nil {
      let id = displayID(of: screen)
      if let spare = spares.popLast() {
        // Re-home a launch-born (healthy, vsync-seeded) spare onto the new display.
        // Moving the window fires NSWindowDidChangeScreenNotification, which makes
        // the Flutter display link re-register on the new CGDirectDisplayID while
        // the already-seeded vsync waiter keeps the render loop running — the fix
        // for "a unit created fresh on a hot-plugged display never repaints".
        spare.window.setFrame(screen.frame, display: true)
        units[id] = spare
      } else {
        // Pool exhausted — only reachable past maxTotalDisplays concurrent displays,
        // i.e. beyond the hardware max. Best-effort direct create; its render loop
        // may not start (engines initialize cleanly only at launch), so a restart
        // (which makes every present display a launch unit) recovers it.
        addUnit(for: screen)
      }
    }
  }

  /// Distribute captured frames to their displays' engines. Each window is
  /// revealed later, in show(displayID:), after its Dart paints the frame and
  /// signals overlayReady — capture-then-show, no blank flash.
  func presentFrames(_ frames: [[String: Any]]) {
    pendingShow.removeAll()
    // Record the cursor display so only ITS overlay takes key focus on reveal —
    // otherwise, with several displays, the last one revealed steals key and the
    // cursor display's editor gets no hover/keyboard (the multi-display freeze).
    keyDisplayID = nil
    for f in frames {
      if (f["isCursorDisplay"] as? Bool) == true, let raw = f["displayId"] as? Int {
        keyDisplayID = CGDirectDisplayID(raw)
      }
    }
    for f in frames {
      guard let raw = f["displayId"] as? Int else { continue }
      let id = CGDirectDisplayID(raw)
      guard let unit = units[id] else { continue }
      pendingShow.insert(id)
      unit.overlay.invokeMethod("onCaptureReady", arguments: ["display": f])
    }
    // One authority decides the active display from here until dismiss.
    startCursorTracking()
  }

  /// Capture-then-show: the window is already on-screen + warm (alpha 0). Once
  /// Dart has painted the frozen frame and signalled overlayReady, reveal it.
  /// The setFrame(display:true) nudge forces a fresh reshape so the just-set
  /// frame is rasterized (also sidesteps the documented blank-on-reshow bug).
  private func show(displayID id: CGDirectDisplayID) {
    guard let unit = units[id] else { return }
    // Use the display's CURRENT frame (a re-homed spare's window.screen may still
    // read its old park display until AppKit settles the move).
    let frame = NSScreen.screens.first(where: { displayID(of: $0) == id })?.frame
      ?? unit.window.screen?.frame ?? unit.window.frame
    unit.window.setFrame(frame, display: true)
    unit.window.alphaValue = 1
    // ALL displays are interactive so the editor can FOLLOW the cursor across
    // them (the cursor poll re-keys the active display via setActiveDisplay).
    // Only the cursor display takes the INITIAL key/active focus on reveal;
    // making every overlay key in turn would let the last-revealed (often
    // NON-cursor) display win. Unknown cursor (nil) -> key this one (single
    // display path).
    unit.window.ignoresMouseEvents = false
    let cursorKnown = keyDisplayID != nil && units[keyDisplayID!] != nil
    if !cursorKnown || id == keyDisplayID {
      if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
      if unit.window.canBecomeKey { unit.window.makeKeyAndOrderFront(nil) }
    }
    unit.window.orderFrontRegardless()
    pendingShow.remove(id)
  }

  // ---- single-authority cross-display follow -----------------------------

  /// Begin polling the global cursor so ONE place decides the active display for
  /// the lifetime of this overlay session. Seeds the active display to the
  /// capture cursor display so the first real cross is what triggers a push.
  private func startCursorTracking() {
    activeID = keyDisplayID
    cursorTimer?.invalidate()
    // ~120 Hz on the common run-loop modes so it keeps firing during AppKit
    // mouse-tracking loops (a drag) too. Polling NSEvent.mouseLocation is cheap
    // and permission-free.
    let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
      self?.tickCursor()
    }
    RunLoop.main.add(t, forMode: .common)
    cursorTimer = t
  }

  private func stopCursorTracking() {
    cursorTimer?.invalidate()
    cursorTimer = nil
    activeID = nil
    setDrawingLock(nil) // re-couple the cursor if a drag was somehow still locked
  }

  /// Enter (id) / leave (nil) a drawing drag on a display. While locked, the poll
  /// freezes the active handoff and a per-drag-event monitor confines the cursor
  /// to the display. On leave, remove the monitor (a final confine snaps the
  /// cursor in so the active editor doesn't jump away as the drag ends).
  func setDrawingLock(_ id: CGDirectDisplayID?) {
    if id != nil {
      if drawingLockID == nil {
        // Match leftMouseDragged ONLY: our own warp emits a mouseMoved, so this
        // can't feed back into itself (which would runaway the cursor).
        dragMonitor = NSEvent.addLocalMonitorForEvents(
          matching: [.leftMouseDragged]
        ) { [weak self] e in
          self?.confineToDrawingDisplay()
          return e
        }
      }
      drawingLockID = id
    } else {
      if drawingLockID != nil {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        confineToDrawingDisplay()
      }
      drawingLockID = nil
    }
  }

  /// Owned hide/show of the system cursor (the active editor engine drives it).
  /// Single owned bool -> NSCursor.hide/unhide stays balanced.
  func setCursorHidden(_ hidden: Bool) {
    guard hidden != cursorHidden else { return }
    cursorHidden = hidden
    if hidden { NSCursor.hide() } else { NSCursor.unhide() }
  }

  /// Native error alert for a BACKGROUND export failure (the overlay is already
  /// hidden, so the in-overlay toast is gone). Hops to the main actor for AppKit.
  func showError(_ message: String) {
    Task { @MainActor in
      let alert = NSAlert()
      alert.messageText = "Glimpr"
      alert.informativeText = message
      alert.alertStyle = .warning
      alert.runModal()
    }
  }

  /// Warp the cursor back to the drawing display's nearest edge if it strayed
  /// out. Coupled (CGAssociate stays on), so cursor speed is unchanged; with the
  /// cursor hidden + the crosshair clamped during the drag this is invisible and
  /// jitter-free. CGDisplayBounds + the CG cursor location are global top-left.
  private func confineToDrawingDisplay() {
    guard let id = drawingLockID, let loc = CGEvent(source: nil)?.location else { return }
    let b = CGDisplayBounds(id)
    guard b.width > 0, !b.contains(loc) else { return }
    let x = min(max(loc.x, b.minX + 1), b.maxX - 1)
    let y = min(max(loc.y, b.minY + 1), b.maxY - 1)
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    CGAssociateMouseAndMouseCursorPosition(1)
  }

  /// One poll: which display holds the GLOBAL cursor right now? On a change,
  /// hand the active role to that display (key + broadcast). NSEvent.mouseLocation
  /// and NSScreen.frame share the Cocoa bottom-left global space, so no flip is
  /// needed to test containment.
  private func tickCursor() {
    // During a draw/crop drag: confine the cursor (backup to the per-event
    // monitor) and do NOT hand off the active role (that would wipe the stroke).
    if drawingLockID != nil {
      confineToDrawingDisplay()
      return
    }
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
    else { return } // between displays / in a gap: keep the current active
    let id = displayID(of: screen)
    guard id != 0, units[id] != nil, id != activeID else { return }
    setActiveDisplay(id, mouseGlobal: mouse, screenFrame: screen.frame)
  }

  /// Authoritatively move the active editor to [id]: make its window key (so the
  /// keyboard follows) and broadcast the new active id + the cursor's
  /// display-local logical point to EVERY engine. Each engine compares the id to
  /// itself to show/hide its HUD, and seeds its crosshair from the point so the
  /// cross lands without a stale frame. One synchronous fan-out, no round-trip.
  private func setActiveDisplay(_ id: CGDirectDisplayID, mouseGlobal: NSPoint, screenFrame: NSRect) {
    activeID = id
    guard let unit = units[id] else { return }
    if !unit.window.isKeyWindow {
      if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
      if unit.window.canBecomeKey { unit.window.makeKey() }
    }
    // Global bottom-left point -> display-local TOP-left logical point (what the
    // Flutter editor uses): x relative to the display's left; y measured down
    // from the display's top (screenFrame.maxY).
    let localX = Double(mouseGlobal.x - screenFrame.minX)
    let localY = Double(screenFrame.maxY - mouseGlobal.y)
    for (_, u) in units {
      u.overlay.invokeMethod(
        "onActiveDisplay",
        arguments: ["activeId": Int(id), "cursorX": localX, "cursorY": localY])
    }
  }

  /// Mirror one display's editor tool/style to the OTHER displays so the active
  /// tool + colour/width/font stay in sync across displays.
  private func broadcastEditorState(from id: CGDirectDisplayID, args: [String: Any]) {
    for (otherID, u) in units where otherID != id {
      u.overlay.invokeMethod("onEditorState", arguments: args)
    }
  }

  /// Esc-cancel or capture-fire: hide all windows atomically. Windows stay
  /// resident on-screen (alpha 0, click-through) so their engines stay warm and
  /// the next capture re-reveals instantly — never orderOut, which would drop
  /// the view off-screen and risk a blank re-show.
  func dismiss() {
    stopCursorTracking()
    setCursorHidden(false) // always restore the system cursor when the overlay closes
    pendingShow.removeAll()
    for (_, u) in units {
      u.window.alphaValue = 0
      u.window.ignoresMouseEvents = true
    }
  }
}
