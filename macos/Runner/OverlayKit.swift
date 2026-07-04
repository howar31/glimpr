import Cocoa
import FlutterMacOS
import ImageIO
import ScreenCaptureKit
import CoreGraphics
import UniformTypeIdentifiers

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

  /// The display under the cursor = the interactive editor display. Uses
  /// NSScreen: NSEvent.mouseLocation and NSScreen.frame share the same Cocoa
  /// bottom-left global space, so NSMouseInRect needs NO coordinate flip (the
  /// old CG/Cocoa flip mismapped multi-display layouts, landing the editor on
  /// the wrong display). Falls back to the main, then the first known, display
  /// so EXACTLY ONE display is always the cursor display — never a no-editor
  /// freeze. Main thread (AppKit).
  func cursorDisplayID() -> CGDirectDisplayID {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
      .flatMap(Self.screenNumber)
      ?? NSScreen.main.flatMap(Self.screenNumber)
      ?? (cachedContent?.displays.first?.displayID ?? CGMainDisplayID())
  }

  /// The cached shareable content, trusted only while its display SET still
  /// matches the attached screens; otherwise refetched fresh (the cache goes
  /// stale across a display add/remove, which would drop a hot-plugged
  /// display from the capture).
  private func freshContent() async throws -> SCShareableContent {
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
    return content
  }

  /// Capture ONE display (the cursor display when [displayID] is nil),
  /// cropped to [rect] (display-local logical points, top-left origin; nil =
  /// whole display) and encoded to the FINAL output format natively — the
  /// direct modes' fast path (no full-display PNG round trip through Dart).
  /// Returns nil when the requested display is not present (the caller picks
  /// the fallback).
  func captureRegion(
    displayID: CGDirectDisplayID?, rect: CGRect?, showsCursor: Bool,
    jpeg: Bool, jpegQuality: Int, decoration: Decoration.Spec? = nil,
    alsoPlain: Bool = false, hdr: Bool = false
  ) async throws -> [String: Any]? {
    let content = try await freshContent()
    let targetID = displayID ?? cursorDisplayID()
    guard let d = content.displays.first(where: { $0.displayID == targetID })
    else { return nil }
    let scale = Self.scaleFactor(for: d.displayID)
    let r = rect
      ?? CGRect(x: 0, y: 0, width: CGFloat(d.width), height: CGFloat(d.height))
    let outW = max(1, Int((r.width * scale).rounded()))
    let outH = max(1, Int((r.height * scale).rounded()))
    let filter = SCContentFilter(display: d, excludingWindows: [])
    // Dual-output HDR (macOS 26+): ONE capture yields the SDR image (converted
    // to sRGB for the classic pipeline) + the HDR image encoded to HEIC. Any
    // failure falls through to the classic SDR-only capture.
    var dualSdr: CGImage? = nil
    var hdrHeic: Data? = nil
    if hdr, #available(macOS 26.0, *), Self.screenHasEdr(d.displayID) {
      PerfLog.mark("sckDualBegin display=\(d.displayID)")
      if let dual = try? await Self.captureDual(
        filter: filter, width: outW, height: outH, sourceRect: r,
        showsCursor: showsCursor) {
        dualSdr = Self.toSrgb(dual.sdr)
        if let h = dual.hdr { hdrHeic = Self.encodeHeic(h) }
      }
      PerfLog.mark("sckDualEnd display=\(d.displayID)")
    }
    let cg: CGImage
    if let dualSdr {
      cg = dualSdr
    } else {
      let cfg = SCStreamConfiguration()
      // sourceRect crops at capture time (content-space points, display-local
      // top-left) — no separate CGImage crop pass.
      cfg.sourceRect = r
      cfg.width = outW
      cfg.height = outH
      cfg.showsCursor = showsCursor
      cfg.colorSpaceName = CGColorSpace.sRGB
      PerfLog.mark("sckImageBegin display=\(d.displayID)")
      cg = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: cfg)
      PerfLog.mark("sckImageEnd display=\(d.displayID)")
    }
    // Opt-in decoration: wrap the captured pixels natively (margin + rounded
    // corners + drop shadow) before encoding — the direct path never hands the
    // pixels back to Dart. A render failure (rare) degrades to the plain image.
    let image = decoration.flatMap { Decoration.render(cg, spec: $0, scale: scale) } ?? cg
    guard let bytes = Decoration.encode(image, jpeg: jpeg, quality: jpegQuality)
    else { return nil }
    PerfLog.mark("regionEncodeEnd display=\(d.displayID) bytes=\(bytes.count)")
    let frame = d.frame
    var dict: [String: Any] = [
      "bytes": FlutterStandardTypedData(bytes: bytes),
      "displayId": Int(d.displayID),
      "x": Double(r.origin.x), "y": Double(r.origin.y),
      "w": Double(r.width), "h": Double(r.height),
      "left": Double(frame.origin.x), "top": Double(frame.origin.y),
      "scaleFactor": Double(scale),
    ]
    // The pin leg's plain rendition: the UNDECORATED capture encoded alongside
    // the decorated bytes (the CGImage is already in hand; one extra encode).
    if alsoPlain, decoration != nil,
       let plain = Decoration.encode(cg, jpeg: jpeg, quality: jpegQuality) {
      dict["plainBytes"] = FlutterStandardTypedData(bytes: plain)
    }
    // The HDR sibling (always undecorated), written by the Dart flow beside
    // the saved SDR file.
    if let hb = hdrHeic {
      dict["hdrBytes"] = FlutterStandardTypedData(bytes: hb)
      dict["hdrExt"] = "heic"
    }
    return dict
  }

  /// macOS 26 dual-dynamic-range one-shot: SDR + HDR CGImages from ONE
  /// capture (SCScreenshotConfiguration, dynamicRange = both). The HDR image
  /// arrives in extended sRGB; the SDR image in the display's colour space.
  @available(macOS 26.0, *)
  static func captureDual(
    filter: SCContentFilter, width: Int, height: Int, sourceRect: CGRect?,
    showsCursor: Bool
  ) async throws -> (sdr: CGImage, hdr: CGImage?)? {
    let cfg = SCScreenshotConfiguration()
    cfg.width = width
    cfg.height = height
    if let r = sourceRect { cfg.sourceRect = r }
    cfg.showsCursor = showsCursor
    cfg.dynamicRange = .bothSDRAndHDR
    let output: SCScreenshotOutput =
      try await withCheckedThrowingContinuation { cont in
        SCScreenshotManager.captureScreenshot(
          contentFilter: filter, configuration: cfg
        ) { output, error in
          if let output {
            cont.resume(returning: output)
          } else {
            cont.resume(throwing: error ?? CaptureError.noDisplays)
          }
        }
      }
    guard let sdr = output.sdrImage else { return nil }
    return (sdr, output.hdrImage)
  }

  /// Whether [displayID]'s screen can show EDR content (HDR-capable AND the
  /// current settings give it headroom above SDR white).
  static func screenHasEdr(_ displayID: CGDirectDisplayID) -> Bool {
    let screen = NSScreen.screens.first { Self.screenNumber($0) == displayID }
    return (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue
      ?? 1.0) > 1.0
  }

  /// Colour-convert to plain 8-bit sRGB by drawing (CG colour-matches), so the
  /// dual capture's SDR leg keeps the Phase-2 "portable sRGB output" behaviour
  /// (the classic path forces sRGB at capture; the dual API returns the
  /// display's own colour space instead).
  static func toSrgb(_ cg: CGImage) -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return cg }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return ctx.makeImage() ?? cg
  }

  /// Encode an HDR CGImage to a true-HDR HEIC. The dual capture's hdrImage
  /// arrives in EXTENDED sRGB, which ImageIO flattens to SDR on a plain encode
  /// (probe-verified: headroom collapses to 1.0) — so convert to the BT.2100
  /// PQ space first; a PQ-tagged 10-bit HEIC is the standard HDR still that
  /// Preview/Photos render with headroom (probe-verified round-trip).
  static func encodeHeic(_ image: CGImage) -> Data? {
    guard let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ),
          let ctx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 16, bytesPerRow: 0, space: pq,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              | CGBitmapInfo.byteOrder16Little.rawValue)
    else { return nil }
    ctx.draw(image,
             in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let pqImage = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
      data as CFMutableData, UTType.heic.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, pqImage, [
      kCGImageDestinationLossyCompressionQuality: 0.92,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
  }

  /// Per-display dicts for a LIVE-SELECT overlay session: the same shape as
  /// captureAll's (geometry + snappable windows + cursor seed) WITHOUT any
  /// SCK capture — no rawBytes, the overlay presents transparent over the
  /// live screen. Pure NSScreen/CG geometry, so it is instant.
  static func liveSelectGeometry() -> [[String: Any]] {
    let mouse = NSEvent.mouseLocation
    var out: [[String: Any]] = []
    for s in NSScreen.screens {
      guard let id = Self.screenNumber(s) else { continue }
      let bounds = CGDisplayBounds(id) // CG global top-left (SCDisplay.frame parity)
      let isCursor = NSMouseInRect(mouse, s.frame, false)
      var dict: [String: Any] = [
        "displayId": Int(id),
        "left": Double(bounds.origin.x), "top": Double(bounds.origin.y),
        "width": Double(bounds.width), "height": Double(bounds.height),
        "scaleFactor": Double(s.backingScaleFactor),
        "isCursorDisplay": isCursor,
        "windows": Self.snappableWindows(displayID: id),
      ]
      if isCursor {
        // Crosshair seed at the real cursor (display-local, top-left origin) —
        // the same Cocoa global -> local conversion as captureAll's.
        dict["cursorX"] = Double(mouse.x - s.frame.minX)
        dict["cursorY"] = Double(s.frame.maxY - mouse.y)
      }
      out.append(dict)
    }
    // Cursor display FIRST (presentation bookkeeping parity with captureAll).
    out.sort {
      (($0["isCursorDisplay"] as? Bool) ?? false)
        && !(($1["isCursorDisplay"] as? Bool) ?? false)
    }
    return out
  }

  /// Captures every display IN PARALLEL and pushes each display's dict to
  /// [onDisplayReady] (main actor) the moment it is ready — the cursor
  /// display's task starts first, so the display the user is looking at
  /// freezes first instead of waiting for the slowest one. Pixels travel as
  /// raw BGRA8888 (no PNG on the freeze path). Returns after every display
  /// was pushed. Throws CaptureError.noDisplays or rethrows SCK errors.
  func captureAll(
    showsCursor: Bool = false, includeCursorImage: Bool = false,
    // Freeze-time HDR retention (the hdr_screenshot setting): called with each
    // HDR display's EDR image, returns the retention generation carried to
    // Dart as hdrGen (thread-safe on the caller's side; the group tasks run
    // concurrently). Nil = no retention (setting off).
    hdrRetainer: ((CGDirectDisplayID, CGImage) -> Int)? = nil,
    onDisplayReady: @escaping @MainActor ([String: Any]) -> Void
  ) async throws {
    let content = try await freshContent()
    let displays = content.displays
    let cursorID = cursorDisplayID()
    let mouse = NSEvent.mouseLocation

    // Pre-compute everything that touches AppKit (scale, geometry, crosshair
    // seed, cursor image, snappable windows) on the calling (main) actor; the
    // group tasks then only touch SCK + CoreGraphics.
    struct Job {
      let display: SCDisplay
      let scale: CGFloat
      let isCursor: Bool
      var dict: [String: Any]
    }
    var jobs: [Job] = []
    for d in displays {
      let scale = Self.scaleFactor(for: d.displayID)
      let frame = d.frame
      let isCursor = d.displayID == cursorID
      var dict: [String: Any] = [
        "displayId": Int(d.displayID),
        "left": Double(frame.origin.x), "top": Double(frame.origin.y),
        "width": Double(frame.size.width), "height": Double(frame.size.height),
        "scaleFactor": Double(scale),
        "isCursorDisplay": isCursor,
        "windows": Self.snappableWindows(displayID: d.displayID),
      ]
      // Seed the crosshair at the real cursor (display-local, top-left origin)
      // instead of the display centre. Same Cocoa global -> local conversion as
      // setActiveDisplay (NSEvent.mouseLocation + NSScreen.frame, bottom-left).
      if isCursor,
         let s = NSScreen.screens.first(where: { Self.screenNumber($0) == d.displayID }) {
        let curX = Double(mouse.x - s.frame.minX) // display-local, top-left origin
        let curY = Double(s.frame.maxY - mouse.y)
        dict["cursorX"] = curX
        dict["cursorY"] = curY
        // The OS cursor image (no second screen capture -> no race): rendered to a
        // native-scale PNG with its display-local top-left. Absent for non-system
        // (custom) cursors -> the overlay simply shows no cursor.
        if includeCursorImage, let cursor = NSCursor.currentSystem,
           let png = Self.cursorPNG(cursor, scale: scale) {
          let hot = cursor.hotSpot // points, top-left origin for cursors
          dict["cursorImage"] = FlutterStandardTypedData(bytes: png)
          dict["cursorLeft"] = curX - Double(hot.x)
          dict["cursorTop"] = curY - Double(hot.y)
        }
      }
      jobs.append(Job(display: d, scale: scale, isCursor: isCursor, dict: dict))
    }
    // Cursor display FIRST so its task starts (and usually finishes) first.
    jobs.sort { $0.isCursor && !$1.isCursor }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for job in jobs {
        group.addTask {
          let d = job.display
          let pixelW = Int(CGFloat(d.width) * job.scale)
          let pixelH = Int(CGFloat(d.height) * job.scale)
          let filter = SCContentFilter(display: d, excludingWindows: [])
          var hdrGen: Int? = nil
          var dualSdr: CGImage? = nil
          // Freeze-time dual capture (macOS 26+, HDR display, setting on): ONE
          // capture yields the SDR frame for the overlay AND the EDR image the
          // annotated export's HDR sibling is composited from. Failure falls
          // through to the classic sRGB capture.
          if let retain = hdrRetainer, #available(macOS 26.0, *),
             Self.screenHasEdr(d.displayID) {
            if let dual = try? await Self.captureDual(
              filter: filter, width: pixelW, height: pixelH, sourceRect: nil,
              showsCursor: showsCursor) {
              dualSdr = Self.toSrgb(dual.sdr)
              if let h = dual.hdr { hdrGen = retain(d.displayID, h) }
            }
          }
          let cgImage: CGImage
          if let dualSdr {
            cgImage = dualSdr
          } else {
            hdrGen = nil
            let cfg = SCStreamConfiguration()
            cfg.width = pixelW
            cfg.height = pixelH
            cfg.showsCursor = showsCursor
            // Capture in sRGB. SCK otherwise tags frames with the display's native
            // wide-gamut profile (e.g. "LG ULTRAFINE"), but Flutter ignores
            // embedded ICC profiles and treats pixels as sRGB — so a wide-gamut
            // frame renders with a visible color cast in the overlay. Producing
            // sRGB pixels makes the overlay match the live screen (the compositor
            // maps sRGB -> display), and exported PNGs become portable sRGB files.
            cfg.colorSpaceName = CGColorSpace.sRGB
            PerfLog.mark("sckImageBegin display=\(d.displayID)")
            cgImage = try await SCScreenshotManager.captureImage(
              contentFilter: filter, configuration: cfg)
            PerfLog.mark("sckImageEnd display=\(d.displayID)")
          }
          // A failed pixel extraction skips this display (parity with the old
          // PNG-encode guard) — the other displays still freeze.
          guard let raw = Self.bgraData(from: cgImage) else { return }
          PerfLog.mark("rawExtractEnd display=\(d.displayID) bytes=\(raw.data.count)")
          var dict = job.dict
          dict["rawBytes"] = FlutterStandardTypedData(bytes: raw.data)
          dict["pixelWidth"] = cgImage.width
          dict["pixelHeight"] = cgImage.height
          dict["rowBytes"] = raw.rowBytes
          if let hdrGen { dict["hdrGen"] = hdrGen }
          await onDisplayReady(dict)
          PerfLog.mark("displayPushed display=\(d.displayID)")
        }
      }
      try await group.waitForAll()
    }
  }

  /// Capture a SINGLE window with its REAL alpha — the area outside the window's
  /// rounded-corner shape is transparent (a desktop-independent window filter
  /// composites only this window). Faithful to the OS-provided window shape (no
  /// assumed corner radius). Shared by two callers via the two public methods
  /// below: the overlay snap MASK ([captureWindowImage], raw alpha) and the
  /// direct "Capture Window" DELIVER ([captureWindowDelivered], final bytes).
  /// nil when no SCWindow matches [windowID], or the window is not
  /// independently capturable (letterboxed) — the caller falls back to a rect
  /// crop. Static so BOTH the control engine (CaptureController) and EVERY
  /// overlay engine can call it — each Flutter engine has its own
  /// `glimpr/capture` handler, so the overlay can't reach the control engine's.
  private static func windowCG(windowID: CGWindowID, showsCursor: Bool,
                               hdr: Bool = false)
    async throws -> (cg: CGImage, scale: CGFloat, hdrHeic: Data?)? {
    // Fetch shareable content fresh (window sets change between captures) and
    // find the target window.
    let shareable = try await SCShareableContent.current
    guard let window = shareable.windows.first(where: { $0.windowID == windowID })
    else { return nil }

    // Size the buffer from the FILTER's own geometry, NOT from SCWindow.frame *
    // NSScreen.backingScaleFactor. SCScreenshotManager renders a desktop-
    // independent window at contentRect.size * pointPixelScale; using the
    // filter's authoritative values keeps the buffer correct on scaled-HiDPI
    // modes where backingScaleFactor can differ from pointPixelScale (both
    // macOS 14+). scalesToFit is Apple-designated for independent window capture.
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let scale = CGFloat(filter.pointPixelScale)
    let content = filter.contentRect
    let wantW = max(1, Int((content.width * scale).rounded()))
    let wantH = max(1, Int((content.height * scale).rounded()))
    // Dual-output HDR (macOS 26+, window on an EDR-capable screen): one
    // capture yields both renditions; failure falls through to the classic
    // SDR-only capture.
    var dualSdr: CGImage? = nil
    var hdrHeic: Data? = nil
    if hdr, #available(macOS 26.0, *), Self.windowScreenHasEdr(window) {
      if let dual = try? await Self.captureDual(
        filter: filter, width: wantW, height: wantH, sourceRect: nil,
        showsCursor: showsCursor) {
        dualSdr = Self.toSrgb(dual.sdr)
        if let h = dual.hdr { hdrHeic = Self.encodeHeic(h) }
      }
    }
    let cg: CGImage
    if let dualSdr {
      cg = dualSdr
    } else {
      hdrHeic = nil
      let cfg = SCStreamConfiguration()
      cfg.width = wantW
      cfg.height = wantH
      cfg.scalesToFit = true
      cfg.showsCursor = showsCursor
      cfg.colorSpaceName = CGColorSpace.sRGB
      PerfLog.mark("windowSckBegin id=\(windowID)")
      cg = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: cfg)
      PerfLog.mark("windowSckEnd id=\(windowID)")
    }
    // Some windows are NOT independently capturable — notably a modern System
    // Settings modal alert, which is drawn into its PARENT window's surface
    // rather than being backed by its own. For those, SCK ignores the per-window
    // filter and returns the PARENT, scaled (preservesAspectRatio) into our
    // buffer with transparent letterbox bands. Used as a snap mask, that carves
    // the (correct) frozen crop into a partial shape — the "half window" bug.
    // A faithfully-captured window fills its own contentRect buffer, so the
    // midpoint of every edge is opaque; if any is transparent the capture is a
    // mismatch -> bail so the caller falls back to a plain rectangular crop.
    guard Self.fillsBuffer(NSBitmapImageRep(cgImage: cg)) else { return nil }
    return (cg, scale, hdrHeic)
  }

  /// Whether the screen holding [window] can show EDR content.
  static func windowScreenHasEdr(_ window: SCWindow) -> Bool {
    var id: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard CGGetDisplaysWithRect(window.frame, 1, &id, &count) == .success,
          count > 0 else { return false }
    return screenHasEdr(id)
  }

  /// Overlay snap MASK: the window's raw BGRA8888 (premultiplied, sRGB) — only
  /// its alpha is used as a dstIn shape mask, so no PNG codec on the wire.
  static func captureWindowImage(windowID: CGWindowID, showsCursor: Bool)
    async throws -> [String: Any]? {
    guard let (cg, scale, _) = try await windowCG(
            windowID: windowID, showsCursor: showsCursor),
          let (data, rowBytes) = bgraData(from: cg) else { return nil }
    PerfLog.mark("windowBgraEnd id=\(windowID) bytes=\(data.count)")
    return [
      "rawBytes": FlutterStandardTypedData(bytes: data),
      "width": cg.width,
      "height": cg.height,
      "scale": Double(scale),
      "rowBytes": rowBytes,
    ]
  }

  /// Direct "Capture Window" DELIVER: the FINAL encoded bytes (PNG/JPEG),
  /// optionally wrapped with native CG decoration first. No annotations, so the
  /// pixels never round-trip through Dart.
  static func captureWindowDelivered(
    windowID: CGWindowID, showsCursor: Bool, jpeg: Bool, jpegQuality: Int,
    decoration: Decoration.Spec?, alsoPlain: Bool = false, hdr: Bool = false
  ) async throws -> [String: Any]? {
    guard let (cg, scale, hdrHeic) = try await windowCG(
      windowID: windowID, showsCursor: showsCursor, hdr: hdr)
    else { return nil }
    let image = decoration.flatMap { Decoration.render(cg, spec: $0, scale: scale) } ?? cg
    guard let bytes = Decoration.encode(image, jpeg: jpeg, quality: jpegQuality)
    else { return nil }
    PerfLog.mark("windowEncodeEnd id=\(windowID) bytes=\(bytes.count)")
    var dict: [String: Any] = [
      "bytes": FlutterStandardTypedData(bytes: bytes),
      "scale": Double(scale),
    ]
    // The pin leg's plain rendition, like captureRegion's: the undecorated
    // window encoded alongside the decorated bytes.
    if alsoPlain, decoration != nil,
       let plain = Decoration.encode(cg, jpeg: jpeg, quality: jpegQuality) {
      dict["plainBytes"] = FlutterStandardTypedData(bytes: plain)
    }
    // The HDR sibling (always undecorated).
    if let hb = hdrHeic {
      dict["hdrBytes"] = FlutterStandardTypedData(bytes: hb)
      dict["hdrExt"] = "heic"
    }
    return dict
  }

  /// True when the midpoint of each edge of [rep] is opaque. A faithfully
  /// captured window fills its own buffer (rounded corners aside), so all four
  /// edge midpoints are solid; transparent ones mean the capture is letterboxed
  /// — a mismatched / non-independent window, not the one we asked for.
  static func fillsBuffer(_ rep: NSBitmapImageRep) -> Bool {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 6, h > 6 else { return true } // too small to judge — trust it
    let inset = 2
    func opaque(_ x: Int, _ y: Int) -> Bool {
      (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
    }
    return opaque(w / 2, inset) && opaque(w / 2, h - 1 - inset)
      && opaque(inset, h / 2) && opaque(w - 1 - inset, h / 2)
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
  /// Window levels a snap may target: normal app windows (0), floating panels
  /// (kCGFloatingWindowLevel 3), and standalone modal alerts
  /// (kCGModalPanelWindowLevel 8). Higher levels are deliberately excluded:
  /// Dock (20), notifications (21), menu bar (24), status items (25), pop-up
  /// menus (101), and our own freeze overlay. Shared with ElementSnap's
  /// target-PID resolution so both snap paths admit the same windows.
  static let snappableWindowLevels: Set<Int> = [0, 3, 8]

  /// The CG-global bounds of a CGWindowList info dict, or nil.
  static func windowBounds(_ w: [String: Any]) -> CGRect? {
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = (b["X"] as? NSNumber)?.doubleValue,
          let y = (b["Y"] as? NSNumber)?.doubleValue,
          let ww = (b["Width"] as? NSNumber)?.doubleValue,
          let hh = (b["Height"] as? NSNumber)?.doubleValue else { return nil }
    return CGRect(x: x, y: y, width: ww, height: hh)
  }

  static func snappableWindows(displayID: CGDirectDisplayID) -> [[String: Any]] {
    let dispBounds = CGDisplayBounds(displayID)
    guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
      as? [[String: Any]] else { return [] }
    var out: [[String: Any]] = []
    for w in infos { // front-to-back
      guard let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
            snappableWindowLevels.contains(layer) else { continue }
      // Skip effectively-invisible windows (e.g. our own warm control window at
      // alpha 0) so they don't become phantom snap targets.
      guard let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
            alpha > 0.05 else { continue }
      guard let r = windowBounds(w) else { continue }
      if r.width < 40 || r.height < 40 { continue }
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
    // When GLIMPR is the frontmost app, take the topmost visible layer-0
    // window of ANY owner: the z-order itself is the right discriminator. A
    // genuinely focused Glimpr window (Settings, editor) is topmost and gets
    // captured; the menu-bar click case (clicking the menu briefly activates
    // this LSUIElement agent) leaves the user's real target topmost — Glimpr's
    // own windows sit behind it or are alpha-0 warm windows — so the
    // previously focused window still wins.
    let myPid = ProcessInfo.processInfo.processIdentifier
    let matchFrontApp = frontPid != myPid
    for w in infos { // front-to-back
      guard let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
            layer == 0,
            let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            !matchFrontApp || owner == frontPid,
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
            alpha > 0.05,
            let r = windowBounds(w)
      else { continue }
      if r.width < 40 || r.height < 40 { continue }
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
    for screen in NSScreen.screens where screenNumber(screen) == displayID {
      return screen.backingScaleFactor
    }
    return 1.0
  }

  /// CGDirectDisplayID for an NSScreen (its "NSScreenNumber" device key).
  static func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  /// CGImage -> tightly-packed BGRA8888 (premultipliedFirst, little-endian),
  /// sRGB. Returns (bytes, rowBytes). The capture cfg already produced sRGB
  /// pixels; rendering into an sRGB context must not re-tag or convert — this
  /// preserves the Phase-2 color fix on the raw path.
  static func bgraData(from cgImage: CGImage) -> (data: Data, rowBytes: Int)? {
    let w = cgImage.width, h = cgImage.height
    guard w > 0, h > 0 else { return nil }
    let rowBytes = w * 4
    var data = Data(count: rowBytes * h)
    let ok = data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
      guard let ctx = CGContext(
        data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return false }
      ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    return ok ? (data, rowBytes) : nil
  }

  /// Render an OS cursor's image to a native-scale PNG (alpha-preserving), drawn at
  /// the display's backing [scale] so it stays crisp regardless of the cursor's own
  /// representation. nil on a zero-sized image / allocation failure.
  static func cursorPNG(_ cursor: NSCursor, scale: CGFloat) -> Data? {
    let img = cursor.image
    let size = img.size // points
    let pxW = Int((size.width * scale).rounded())
    let pxH = Int((size.height * scale).rounded())
    guard pxW > 0, pxH > 0,
          let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
  }
}

// MARK: - OverlayWindow

/// A frameless, transparent, above-the-menu-bar overlay window pinned to one
/// NSScreen. One instance per display (a single window cannot span displays
/// when "Displays have separate Spaces" is ON — the macOS default).
final class OverlayWindow: NSWindow {
  // While Settings is open over a paused freeze (⌘,) the window is LOCKED: it
  // stays visible but must not become key on a stray click, or it would steal
  // keyboard focus from the Settings window (e.g. the shortcut recorder).
  var locked = false
  // Borderless windows are not key/main by default; without these overrides,
  // keyboard events (Esc, future arrow-nudge) never arrive.
  override var canBecomeKey: Bool { !locked }
  override var canBecomeMain: Bool { !locked }

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

  // Freeze-retained HDR base per display (HDR display + the hdr_screenshot
  // setting on at capture): the EDR CGImage the annotated export's HDR sibling
  // is composited from (encodeHdrRegion). Latest capture generation only;
  // overwritten each capture, released on dismiss. Lock-guarded — captureAll's
  // group tasks retain concurrently.
  private var hdrBases: [CGDirectDisplayID: (image: CGImage, gen: Int)] = [:]
  private var hdrGen = 0
  private let hdrLock = NSLock()

  /// New capture: bump the generation and drop the previous bases.
  func beginHdrRetention() {
    hdrLock.lock()
    hdrGen += 1
    hdrBases = [:]
    hdrLock.unlock()
  }

  /// Retain [image] as [id]'s HDR base; returns the generation for the dict.
  func retainHdr(_ id: CGDirectDisplayID, _ image: CGImage) -> Int {
    hdrLock.lock()
    defer { hdrLock.unlock() }
    hdrBases[id] = (image, hdrGen)
    return hdrGen
  }

  /// The retained base for [id] iff [gen] is still current (a stale layer's
  /// export gets nil and skips its HDR sibling).
  func hdrBase(for id: CGDirectDisplayID, gen: Int) -> CGImage? {
    hdrLock.lock()
    defer { hdrLock.unlock() }
    guard let e = hdrBases[id], e.gen == gen else { return nil }
    return e.image
  }

  private func clearHdrBases() {
    hdrLock.lock()
    hdrBases = [:]
    hdrLock.unlock()
  }
  // The display the cursor is on at capture = the interactive editor. Only its
  // window takes key/active focus on reveal (see show()). nil = unknown.
  private var keyDisplayID: CGDirectDisplayID?

  // True while a capture is paused for ⌘, Settings (suspend/resume): the freeze
  // windows are hidden but resident, and the Dart state is intact, so resume()
  // restores the exact same session.
  private(set) var isSuspended = false

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
    ScreenCapturer.screenNumber(screen) ?? 0
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
      EncodeChannel.register(messenger: msgr)
      ClipboardChannel.register(messenger: msgr)
      SoundChannel.register(messenger: msgr)
      let control = FlutterMethodChannel(name: "glimpr/capture", binaryMessenger: msgr)
      control.setMethodCallHandler { [weak self, weak vc] call, result in
        guard let self = self else { result(nil); return }
        switch call.method {
        case "overlayReady":
          if let vc = vc, let id = self.displayID(forVC: vc) {
            PerfLog.mark("overlayReady display=\(id)")
            self.show(displayID: id)
          }
          result(nil)
        case "broadcastEditorState":
          if let vc = vc, let id = self.displayID(forVC: vc),
             let a = call.arguments as? [String: Any] {
            self.broadcastEditorState(from: id, args: a)
          }
          result(nil)
        case "dismissOverlay": self.dismiss(); result(nil)
        // Stop the record-select loupe feed while keeping the window up (the
        // session beneath a confirmed/cancelled record-select stays visible, so
        // dismiss() — which would also endLiveSelect — is skipped). Idempotent.
        case "stopLoupeFeed": self.endLiveSelect(); result(nil)
        // Menu-bar processing pulse — relay to the control engine's status item
        // (the overlay capture lifecycle lives in this engine). The optional
        // label is the pulsing icon's hover tooltip.
        case "setProcessing":
          let a = call.arguments as? [String: Any]
          let active = a?["active"] as? Bool ?? false
          let label = a?["label"] as? String
          MainFlutterWindow.shared?.setCaptureProcessing(active, label: label)
          result(nil)
        // Hide ONLY the calling engine's window (a layer pop reached an
        // engine with no frame for the restored layer).
        case "hideOverlay":
          if let vc = vc, let id = self.displayID(forVC: vc) {
            self.hide(displayID: id)
          }
          result(nil)
        // Dart-side perf marks from the overlay engines (frame stats,
        // broadcast counters) land in the same unified-log perf category.
        case "perfMark":
          if let label = (call.arguments as? [String: Any])?["label"] as? String {
            PerfLog.mark(label)
          }
          result(nil)
        // An overlay-engine capture flow wrote the shared recent-images store:
        // forward a refresh to the editor engine (gallery + Open Recent menu).
        // Windows always relayed this; macOS only had the control-engine relay,
        // so interactive captures did not live-refresh until the editor window
        // became key.
        case "recentChanged":
          DispatchQueue.main.async {
            MainFlutterWindow.shared?.notifyRecentChanged()
          }
          result(nil)
        // After-capture flow (overlay engine): open the exported file in the
        // image editor — routed to the control window's warm editor.
        case "openInEditor":
          if let path = (call.arguments as? [String: Any])?["path"] as? String {
            DispatchQueue.main.async {
              MainFlutterWindow.shared?.openImageFromExternal(path)
            }
          }
          result(nil)
        // After-capture flow (overlay engine): macOS share sheet.
        case "shareSheet":
          if let path = (call.arguments as? [String: Any])?["path"] as? String {
            DispatchQueue.main.async {
              MainFlutterWindow.shared?.showShareSheet(path: path)
            }
          }
          result(nil)
        // After-capture flow (overlay engine): always-on-top pin window.
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
        // ⌘, from the capture overlay: PAUSE the freeze (keep it visible, masked)
        // and reveal Settings ABOVE the shield-level overlay; hideSettings resumes
        // when Settings closes.
        case "openSettings":
          self.suspend()
          MainFlutterWindow.shared?.revealSettings(aboveOverlay: true)
          result(nil)
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
        // Live-select loupe pixels: a span×span RGBA patch around the native
        // pixel (x, y) from this display's live stream; nil before the first
        // frame (the loupe just stays empty).
        case "loupeSample":
          if let vc = vc, let id = self.displayID(forVC: vc),
             let a = call.arguments as? [String: Any],
             let x = a["x"] as? Int, let y = a["y"] as? Int,
             let span = a["span"] as? Int,
             let data = self.loupeSample(displayID: id, x: x, y: y, span: span) {
            result(FlutterStandardTypedData(bytes: data))
          } else {
            result(nil)
          }
        // Live-select confirm/cancel: relay the chosen target (or the
        // cancellation) to the CONTROL engine's record channel — the overlay
        // engine cannot reach it directly.
        case "recordSelection":
          if let a = call.arguments as? [String: Any] {
            DispatchQueue.main.async {
              MainFlutterWindow.shared?.relayRecordSelection(a)
            }
          }
          result(nil)
        case "encodeHdrRegion":
          // The annotated export's HDR sibling: composite the Dart-supplied
          // overlay segments + effect ops onto this display's freeze-retained
          // EDR image and return the encoded HEIC. Nil reply = no base
          // retained (SDR display / setting off / stale layer) -> Dart skips.
          let a = (call.arguments as? [String: Any]) ?? [:]
          let gen = (a["gen"] as? NSNumber)?.intValue ?? -1
          guard let vc = vc, let id = self.displayID(forVC: vc),
                let base = self.hdrBase(for: id, gen: gen) else {
            result(nil)
            return
          }
          // Heavy CPU work off the platform thread; reply back on it.
          DispatchQueue.global(qos: .userInitiated).async {
            let heic = HdrCompositor.composeHeic(base: base, args: a)
            DispatchQueue.main.async {
              if let heic {
                result([
                  "bytes": FlutterStandardTypedData(bytes: heic),
                  "ext": "heic",
                ])
              } else {
                result(nil)
              }
            }
          }
        case "captureWindowImage":
          // The overlay snap fetches the window's real alpha here (this engine
          // has its OWN glimpr/capture handler, separate from the control one).
          let a = call.arguments as? [String: Any]
          let wid = (a?["windowId"] as? NSNumber)?.uint32Value ?? 0
          let cursor = (a?["showsCursor"] as? Bool) ?? false
          Task { @MainActor in
            do {
              let img = try await ScreenCapturer.captureWindowImage(
                windowID: CGWindowID(wid), showsCursor: cursor)
              result(img)
            } catch {
              result(FlutterError(
                code: "capture_failed", message: "\(error)", details: nil))
            }
          }
        // Precise element snap (Advanced experiment): the AX element under a
        // display-local logical point (top-left). AX is a SYNCHRONOUS
        // cross-process call to the target app, so run it on a background queue
        // with the short messaging timeout ElementSnap installs — a hung target
        // yields nil (Dart falls back to window snap) instead of stalling the
        // overlay. Returns nil without the AX permission too.
        case "elementSnapAt":
          if let a = call.arguments as? [String: Any],
             let id = (a["displayId"] as? NSNumber)?.uint32Value,
             let x = a["x"] as? Double, let y = a["y"] as? Double {
            let walk = (a["walk"] as? Int) ?? 0
            let origin = CGDisplayBounds(CGDirectDisplayID(id)).origin
            let global = CGPoint(x: origin.x + x, y: origin.y + y)
            DispatchQueue.global(qos: .userInteractive).async {
              let out = ElementSnap.query(
                globalTopLeft: global, walk: walk, displayOrigin: origin)
              DispatchQueue.main.async { result(out) }
            }
          } else {
            result(nil)
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

  /// Seed a capture presentation: reset the pending bookkeeping and record the
  /// cursor display so only ITS overlay takes key focus on reveal — otherwise,
  /// with several displays, the last one revealed steals key and the cursor
  /// display's editor gets no hover/keyboard (the multi-display freeze). Called
  /// once per capture, BEFORE the parallel per-display pushes start.
  func presentBegin(cursorDisplayID: CGDirectDisplayID?) {
    pendingShow.removeAll()
    keyDisplayID = cursorDisplayID
    // One authority decides the active display from here until dismiss.
    startCursorTracking()
  }

  /// Push ONE display's frame to its engine the moment its capture is ready.
  /// Each window is revealed later, in show(displayID:), after its Dart paints
  /// the frame and signals overlayReady — capture-then-show, no blank flash.
  /// [liveSelect]: a recording live-select session — no frozen pixels in [f];
  /// the overlay presents transparent over the live screen.
  func presentFrame(_ f: [String: Any], pinOnly: Bool = false,
                    liveSelect: Bool = false) {
    guard let raw = f["displayId"] as? Int else { return }
    let id = CGDirectDisplayID(raw)
    guard let unit = units[id] else { return }
    pendingShow.insert(id)
    unit.overlay.invokeMethod(
      "onCaptureReady",
      arguments: ["display": f, "pinOnly": pinOnly, "liveSelect": liveSelect])
  }

  // ---- live-select (recording) session ------------------------------------

  /// True while a live-select session is presented; guards re-entrant capture
  /// triggers (a freeze capture stacking onto a transparent session and vice
  /// versa would corrupt both).
  private(set) var liveSelectActive = false
  private var liveSources: [CGDirectDisplayID: LiveFrameSource] = [:]

  /// Start the per-display live-pixel feeds for the loupe (every overlay
  /// window excluded so the loupe sees TRUE pixels, not the veil).
  func beginLiveSelect() {
    endLiveSelect() // idempotent: stop any prior feed before starting a fresh one
    liveSelectActive = true
    let excluded = units.values.map { $0.window.windowNumber }
    for (id, _) in units {
      let src = LiveFrameSource()
      src.start(displayID: id, excludingWindowNumbers: excluded)
      liveSources[id] = src
    }
    PerfLog.mark("loupeFeedsStart displayCount=\(liveSources.count)")
  }

  /// A span×span RGBA patch around a native pixel for [displayID]'s loupe,
  /// or nil while the display's stream has no frame yet.
  func loupeSample(displayID: CGDirectDisplayID, x: Int, y: Int, span: Int) -> Data? {
    liveSources[displayID]?.sample(centerX: x, centerY: y, span: span)
  }

  private func endLiveSelect() {
    guard liveSelectActive else { return }
    liveSelectActive = false
    PerfLog.mark("loupeFeedsStop displayCount=\(liveSources.count)")
    for (_, s) in liveSources { s.stop() }
    liveSources.removeAll()
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
    PerfLog.mark("overlayShown display=\(id)")
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

  /// Record hotkey pressed while a record-select is in flight: relay to EVERY
  /// overlay engine so each resurfaces a suspended picker or cancels a
  /// foreground one based on its own state (control engine -> CaptureChannel).
  func relayRecordSelectHotkey() {
    for (_, u) in units {
      u.overlay.invokeMethod("onRecordSelectHotkey", arguments: nil)
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
    isSuspended = false
    endLiveSelect()
    clearHdrBases() // the annotated export consumed (or forfeited) them
    for (_, u) in units {
      u.window.alphaValue = 0
      u.window.ignoresMouseEvents = true
    }
  }

  /// Hide ONE display's overlay window (a layer pop restored a layer this
  /// display has no frame for, e.g. it was hot-plugged mid-session). Same
  /// resident-warm treatment as dismiss(): alpha 0 + click-through; the
  /// session (cursor poll, other windows) keeps running.
  func hide(displayID id: CGDirectDisplayID) {
    guard let unit = units[id] else { return }
    unit.window.alphaValue = 0
    unit.window.ignoresMouseEvents = true
  }

  /// ⌘, from the overlay: PAUSE the freeze for the Settings detour. The windows
  /// stay VISIBLE (so it never looks cancelled) — a Dart mask dims them and
  /// absorbs input; the Settings window is raised above the shield so it shows on
  /// top. We only: stop the cursor poll (no key theft), restore the system cursor
  /// (so it's usable over Settings), and LOCK the windows (a stray click can't
  /// steal key focus). The Dart frame + annotations are untouched.
  func suspend() {
    isSuspended = true
    stopCursorTracking()
    setCursorHidden(false)
    pendingShow.removeAll()
    for (_, u) in units {
      u.window.locked = true
      u.overlay.invokeMethod("onSettingsOpen", arguments: nil)
    }
  }

  /// Settings closed after a suspend: unlock + re-arm the cursor poll (the
  /// windows were never hidden) and tell each overlay engine to drop the mask +
  /// re-read settings, so e.g. a new loupe size applies immediately.
  func resume() {
    guard isSuspended else { return }
    isSuspended = false
    for (_, u) in units {
      u.window.locked = false
    }
    startCursorTracking()
    for (_, u) in units {
      u.overlay.invokeMethod("onResume", arguments: nil)
    }
    // Settings took key focus; the cursor poll only re-keys on a CHANGE, so the
    // overlay would stay non-key (keyboard dead) until the cursor crosses
    // displays. Force the window under the cursor back to key now so shortcuts
    // resume immediately (the Dart side also re-requests its FocusNode).
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    let mouse = NSEvent.mouseLocation
    let id =
      NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
      .map { displayID(of: $0) } ?? keyDisplayID
    if let id = id, let unit = units[id], unit.window.canBecomeKey {
      unit.window.makeKeyAndOrderFront(nil)
    }
  }
}

// MARK: - HdrCompositor

/// The native HDR compositor for the annotated overlay export: replays the
/// Dart editor's z-ordered output (overlay segments + base-sampling effect
/// ops) on the freeze-retained EDR image and encodes the result as a PQ HEIC.
///
/// Space contract (mirrors lib/editor/hdr_plan.dart + the Windows
/// hdr_compose.cpp): the EDR image is EXTENDED sRGB — gamma-encoded relative
/// to SDR white — which IS the working domain, so every blend/filter here
/// matches the Dart (sRGB) composite exactly wherever the base is within SDR
/// range. Effect ops sample the PRISTINE base in FRAME space; overlay segments
/// are CROP-space straight-alpha RGBA bitmaps. Lives inside OverlayKit.swift
/// (new Swift files need 4 pbxproj entries — project rule: extend an existing
/// compiled file instead).
enum HdrCompositor {
  /// [args] is the raw encodeHdrRegion payload (crop, items, optional mask).
  static func composeHeic(base: CGImage, args: [String: Any]) -> Data? {
    let baseW = base.width, baseH = base.height
    guard baseW > 0, baseH > 0 else { return nil }
    let cropX = Int(((args["x"] as? NSNumber)?.doubleValue ?? 0).rounded())
    let cropY = Int(((args["y"] as? NSNumber)?.doubleValue ?? 0).rounded())
    let cropW = Int(((args["w"] as? NSNumber)?.doubleValue ?? 0).rounded())
    let cropH = Int(((args["h"] as? NSNumber)?.doubleValue ?? 0).rounded())
    guard cropW > 0, cropH > 0 else { return nil }

    // Rasterise the base ONCE into a float RGBA buffer (extended sRGB, gamma).
    guard let ext = CGColorSpace(name: CGColorSpace.extendedSRGB) else { return nil }
    let floatInfo = CGBitmapInfo.floatComponents.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Little.rawValue
    var basePx = [Float](repeating: 0, count: baseW * baseH * 4)
    let ok: Bool = basePx.withUnsafeMutableBytes { p in
      guard let ctx = CGContext(
        data: p.baseAddress, width: baseW, height: baseH, bitsPerComponent: 32,
        bytesPerRow: baseW * 16, space: ext, bitmapInfo: floatInfo)
      else { return false }
      ctx.draw(base, in: CGRect(x: 0, y: 0, width: baseW, height: baseH))
      return true
    }
    guard ok else { return nil }

    // The pristine-base fetch (clamp-to-edge; alpha is 1 -> premul == straight).
    func fetch(_ x: Int, _ y: Int) -> (Float, Float, Float) {
      let cx = min(max(x, 0), baseW - 1)
      let cy = min(max(y, 0), baseH - 1)
      let i = (cy * baseW + cx) * 4
      return (basePx[i], basePx[i + 1], basePx[i + 2])
    }
    func fetchBilinear(_ fx: Double, _ fy: Double) -> (Float, Float, Float) {
      let px = fx - 0.5, py = fy - 0.5
      let x0 = Int(px.rounded(.down)), y0 = Int(py.rounded(.down))
      let tx = Float(px - Double(x0)), ty = Float(py - Double(y0))
      let c00 = fetch(x0, y0), c10 = fetch(x0 + 1, y0)
      let c01 = fetch(x0, y0 + 1), c11 = fetch(x0 + 1, y0 + 1)
      func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
      return (
        mix(mix(c00.0, c10.0, tx), mix(c01.0, c11.0, tx), ty),
        mix(mix(c00.1, c10.1, tx), mix(c01.1, c11.1, tx), ty),
        mix(mix(c00.2, c10.2, tx), mix(c01.2, c11.2, tx), ty)
      )
    }

    // Working buffer: crop-space RGBA float (straight alpha, managed by hand).
    var work = [Float](repeating: 0, count: cropW * cropH * 4)
    for y in 0..<cropH {
      for x in 0..<cropW {
        let (r, g, b) = fetch(cropX + x, cropY + y)
        let i = (y * cropW + x) * 4
        work[i] = r; work[i + 1] = g; work[i + 2] = b; work[i + 3] = 1
      }
    }

    // ---- small-image helpers (the downsampled effect sources) --------------
    struct Small { var w = 0, h = 0; var rgb: [Float] = [] }
    func downsample(_ srcX0: Double, _ srcY0: Double, _ srcX1: Double,
                    _ srcY1: Double, _ gw: Int, _ gh: Int) -> Small {
      var out = Small(w: gw, h: gh, rgb: [Float](repeating: 0, count: gw * gh * 3))
      let cw = (srcX1 - srcX0) / Double(gw), ch = (srcY1 - srcY0) / Double(gh)
      for gy in 0..<gh {
        for gx in 0..<gw {
          let x0 = Int((srcX0 + Double(gx) * cw).rounded(.down))
          let y0 = Int((srcY0 + Double(gy) * ch).rounded(.down))
          let x1 = max(x0 + 1, Int((srcX0 + Double(gx + 1) * cw).rounded(.up)))
          let y1 = max(y0 + 1, Int((srcY0 + Double(gy + 1) * ch).rounded(.up)))
          var acc: (Float, Float, Float) = (0, 0, 0)
          var n = 0
          for y in y0..<y1 {
            for x in x0..<x1 {
              let t = fetch(x, y)
              acc.0 += t.0; acc.1 += t.1; acc.2 += t.2; n += 1
            }
          }
          let i = (gy * gw + gx) * 3
          if n > 0 {
            out.rgb[i] = acc.0 / Float(n)
            out.rgb[i + 1] = acc.1 / Float(n)
            out.rgb[i + 2] = acc.2 / Float(n)
          }
        }
      }
      return out
    }
    func gaussianBlur(_ img: inout Small, sigma: Double) {
      guard sigma > 0.05, img.w > 0, img.h > 0 else { return }
      let radius = max(1, Int((sigma * 3).rounded(.up)))
      var kernel = [Float](repeating: 0, count: radius + 1)
      var sum = 0.0
      for i in 0...radius {
        kernel[i] = Float(exp(-Double(i * i) / (2 * sigma * sigma)))
        sum += Double(kernel[i]) * (i == 0 ? 1 : 2)
      }
      for i in 0...radius { kernel[i] = Float(Double(kernel[i]) / sum) }
      var tmp = img.rgb
      for y in 0..<img.h { // horizontal
        for x in 0..<img.w {
          var acc: (Float, Float, Float) = (0, 0, 0)
          for k in -radius...radius {
            let sx = min(max(x + k, 0), img.w - 1)
            let i = (y * img.w + sx) * 3
            let kv = kernel[abs(k)]
            acc.0 += tmp[i] * kv; acc.1 += tmp[i + 1] * kv; acc.2 += tmp[i + 2] * kv
          }
          let o = (y * img.w + x) * 3
          img.rgb[o] = acc.0; img.rgb[o + 1] = acc.1; img.rgb[o + 2] = acc.2
        }
      }
      tmp = img.rgb
      for y in 0..<img.h { // vertical
        for x in 0..<img.w {
          var acc: (Float, Float, Float) = (0, 0, 0)
          for k in -radius...radius {
            let sy = min(max(y + k, 0), img.h - 1)
            let i = (sy * img.w + x) * 3
            let kv = kernel[abs(k)]
            acc.0 += tmp[i] * kv; acc.1 += tmp[i + 1] * kv; acc.2 += tmp[i + 2] * kv
          }
          let o = (y * img.w + x) * 3
          img.rgb[o] = acc.0; img.rgb[o + 1] = acc.1; img.rgb[o + 2] = acc.2
        }
      }
    }
    func sampleSmall(_ img: Small, _ fx: Double, _ fy: Double)
      -> (Float, Float, Float) {
      let px = fx - 0.5, py = fy - 0.5
      let x0 = Int(px.rounded(.down)), y0 = Int(py.rounded(.down))
      let tx = Float(px - Double(x0)), ty = Float(py - Double(y0))
      func cl(_ v: Int, _ hi: Int) -> Int { min(max(v, 0), hi) }
      let xa = cl(x0, img.w - 1), xb = cl(x0 + 1, img.w - 1)
      let ya = cl(y0, img.h - 1), yb = cl(y0 + 1, img.h - 1)
      func px3(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        let i = (y * img.w + x) * 3
        return (img.rgb[i], img.rgb[i + 1], img.rgb[i + 2])
      }
      let c00 = px3(xa, ya), c10 = px3(xb, ya), c01 = px3(xa, yb), c11 = px3(xb, yb)
      func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
      return (
        mix(mix(c00.0, c10.0, tx), mix(c01.0, c11.0, tx), ty),
        mix(mix(c00.1, c10.1, tx), mix(c01.1, c11.1, tx), ty),
        mix(mix(c00.2, c10.2, tx), mix(c01.2, c11.2, tx), ty)
      )
    }
    // Mirror of raster.dart blurRegion: inflate by 3 sigma, downsample by
    // max(1, floor(sigma/2)), small gaussian, bilinear-stretch back.
    func blurRegion(_ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double,
                    _ sigma: Double) -> (img: Small, x0: Double, y0: Double,
                                         factor: Double) {
      let margin = (sigma * 3).rounded(.up)
      let sx0 = max(0, rx - margin), sy0 = max(0, ry - margin)
      let sx1 = min(Double(baseW), rx + rw + margin)
      let sy1 = min(Double(baseH), ry + rh + margin)
      let factor = max(1, (sigma / 2).rounded(.down))
      let gw = max(1, Int(((sx1 - sx0) / factor).rounded(.up)))
      let gh = max(1, Int(((sy1 - sy0) / factor).rounded(.up)))
      var img = downsample(sx0, sy0, sx1, sy1, gw, gh)
      gaussianBlur(&img, sigma: sigma / factor)
      return (img, sx0, sy0, factor)
    }
    func erf(_ x0: Float) -> Float {
      let sign: Float = x0 < 0 ? -1 : 1
      let x = abs(x0)
      let t = 1 / (1 + 0.3275911 * x)
      let y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
        - 0.284496736) * t + 0.254829592) * t * exp(-x * x)
      return sign * y
    }

    // ---- replay the item list ----------------------------------------------
    let items = (args["items"] as? [Any]) ?? []
    for entry in items {
      guard let m = entry as? [String: Any], let t = m["t"] as? String else { continue }
      func num(_ k: String) -> Double { (m[k] as? NSNumber)?.doubleValue ?? 0 }
      switch t {
      case "overlay":
        guard let td = m["bytes"] as? FlutterStandardTypedData else { continue }
        let ow = Int(num("w")), oh = Int(num("h"))
        let bytes = [UInt8](td.data)
        guard bytes.count >= ow * oh * 4 else { continue }
        let w = min(ow, cropW), h = min(oh, cropH)
        for y in 0..<h {
          for x in 0..<w {
            let s = (y * ow + x) * 4
            let a = Float(bytes[s + 3]) / 255
            if a <= 0 { continue }
            let d = (y * cropW + x) * 4
            for c in 0..<3 {
              let o = Float(bytes[s + c]) / 255
              work[d + c] = o * a + work[d + c] * (1 - a)
            }
          }
        }
      case "blur":
        let rx = num("x"), ry = num("y"), rw = num("w"), rh = num("h")
        let blur = blurRegion(rx, ry, rw, rh, num("sigma"))
        let x0 = max(Int(rx.rounded(.down)), cropX)
        let y0 = max(Int(ry.rounded(.down)), cropY)
        let x1 = min(Int((rx + rw).rounded(.up)), cropX + cropW)
        let y1 = min(Int((ry + rh).rounded(.up)), cropY + cropH)
        guard x0 < x1, y0 < y1 else { continue }
        for y in y0..<y1 {
          for x in x0..<x1 {
            let s = sampleSmall(blur.img,
                                (Double(x) + 0.5 - blur.x0) / blur.factor,
                                (Double(y) + 0.5 - blur.y0) / blur.factor)
            let d = ((y - cropY) * cropW + (x - cropX)) * 4
            work[d] = s.0; work[d + 1] = s.1; work[d + 2] = s.2
          }
        }
      case "pixelate":
        let rx = num("x"), ry = num("y"), rw = num("w"), rh = num("h")
        let cell = max(1, num("cell"))
        let gw = max(1, Int((rw / cell).rounded(.up)))
        let gh = max(1, Int((rh / cell).rounded(.up)))
        let grid = downsample(rx, ry, rx + rw, ry + rh, gw, gh)
        let x0 = max(Int(rx.rounded(.down)), cropX)
        let y0 = max(Int(ry.rounded(.down)), cropY)
        let x1 = min(Int((rx + rw).rounded(.up)), cropX + cropW)
        let y1 = min(Int((ry + rh).rounded(.up)), cropY + cropH)
        guard x0 < x1, y0 < y1 else { continue }
        for y in y0..<y1 {
          for x in x0..<x1 {
            var gx = Int((Double(x) + 0.5 - rx) / rw * Double(gw))
            var gy = Int((Double(y) + 0.5 - ry) / rh * Double(gh))
            gx = min(max(gx, 0), gw - 1)
            gy = min(max(gy, 0), gh - 1)
            let i = (gy * gw + gx) * 3
            let d = ((y - cropY) * cropW + (x - cropX)) * 4
            work[d] = grid.rgb[i]; work[d + 1] = grid.rgb[i + 1]
            work[d + 2] = grid.rgb[i + 2]
          }
        }
      case "magnify":
        let dx = num("dx"), dy = num("dy"), dw = num("dw"), dh = num("dh")
        guard dw > 0, dh > 0 else { continue }
        let x0 = max(Int(dx.rounded(.down)), cropX)
        let y0 = max(Int(dy.rounded(.down)), cropY)
        let x1 = min(Int((dx + dw).rounded(.up)), cropX + cropW)
        let y1 = min(Int((dy + dh).rounded(.up)), cropY + cropH)
        guard x0 < x1, y0 < y1 else { continue }
        let sx = num("sx"), sy = num("sy"), sw = num("sw"), sh = num("sh")
        for y in y0..<y1 {
          for x in x0..<x1 {
            let u = sx + (Double(x) + 0.5 - dx) / dw * sw
            let v = sy + (Double(y) + 0.5 - dy) / dh * sh
            let s = fetchBilinear(u, v)
            let d = ((y - cropY) * cropW + (x - cropX)) * 4
            work[d] = s.0; work[d + 1] = s.1; work[d + 2] = s.2
          }
        }
      case "spotlight":
        let effect = (m["effect"] as? String) ?? "none"
        let dim = Float(min(max(num("dim"), 0), 1))
        let feather = num("feather")
        if effect == "none" && dim <= 0 { continue }
        var blur: (img: Small, x0: Double, y0: Double, factor: Double)? = nil
        var grid: Small? = nil
        var gw = 0, gh = 0
        if effect == "blur" {
          blur = blurRegion(0, 0, Double(baseW), Double(baseH), num("strength"))
        } else if effect == "pixelate" {
          let cell = max(1, num("strength"))
          gw = max(1, Int((Double(baseW) / cell).rounded(.up)))
          gh = max(1, Int((Double(baseH) / cell).rounded(.up)))
          grid = downsample(0, 0, Double(baseW), Double(baseH), gw, gh)
        }
        let holes = (m["holes"] as? [Any]) ?? []
        struct H { let x, y, w, h, r: Double }
        var hs: [H] = []
        for hv in holes {
          guard let hm = hv as? [String: Any] else { continue }
          func hn(_ k: String) -> Double { (hm[k] as? NSNumber)?.doubleValue ?? 0 }
          hs.append(H(x: hn("x"), y: hn("y"), w: hn("w"), h: hn("h"),
                      r: hn("radius")))
        }
        let layerA0: Float = effect != "none" ? 1 : dim
        for wy in 0..<cropH {
          for wx in 0..<cropW {
            let fx = Double(cropX + wx) + 0.5, fy = Double(cropY + wy) + 0.5
            var lr: Float = 0, lg: Float = 0, lb: Float = 0
            if let blur {
              let s = sampleSmall(blur.img, (fx - blur.x0) / blur.factor,
                                  (fy - blur.y0) / blur.factor)
              lr = s.0 * (1 - dim); lg = s.1 * (1 - dim); lb = s.2 * (1 - dim)
            } else if let grid {
              var gx = Int(fx / Double(baseW) * Double(gw))
              var gy = Int(fy / Double(baseH) * Double(gh))
              gx = min(max(gx, 0), gw - 1)
              gy = min(max(gy, 0), gh - 1)
              let i = (gy * gw + gx) * 3
              lr = grid.rgb[i] * (1 - dim); lg = grid.rgb[i + 1] * (1 - dim)
              lb = grid.rgb[i + 2] * (1 - dim)
            }
            var la = layerA0
            for hole in hs {
              // Feathered rounded-rect coverage (~ MaskFilter.blur): signed
              // distance -> gaussian edge via erf.
              let hw = hole.w / 2, hh = hole.h / 2
              let r = min(hole.r, min(hw, hh))
              let qx = abs(fx - (hole.x + hw)) - (hw - r)
              let qy = abs(fy - (hole.y + hh)) - (hh - r)
              let ox = max(qx, 0), oy = max(qy, 0)
              let dist = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
              let cov: Float
              if feather <= 0.01 {
                cov = dist < 0 ? 1 : 0
              } else {
                cov = 0.5 * (1 - erf(Float(dist / (feather * 1.4142135))))
              }
              if cov <= 0 { continue }
              let keep = 1 - cov
              la *= keep; lr *= keep; lg *= keep; lb *= keep
            }
            if la <= 0 && lr <= 0 && lg <= 0 && lb <= 0 { continue }
            let d = (wy * cropW + wx) * 4
            work[d] = lr + work[d] * (1 - la)
            work[d + 1] = lg + work[d + 1] * (1 - la)
            work[d + 2] = lb + work[d + 2] * (1 - la)
          }
        }
      default:
        continue
      }
    }

    // Window-snap silhouette: dstIn alpha, mask stretched over the crop.
    if let td = m0MaskData(args) {
      let mw = Int(((args["maskW"] as? NSNumber)?.doubleValue ?? 0))
      let mh = Int(((args["maskH"] as? NSNumber)?.doubleValue ?? 0))
      var mrow = Int(((args["maskRowBytes"] as? NSNumber)?.doubleValue ?? 0))
      if mrow <= 0 { mrow = mw * 4 }
      if mw > 0, mh > 0 {
        let mask = [UInt8](td.data)
        func alphaAt(_ x: Int, _ y: Int) -> Float {
          let cx = min(max(x, 0), mw - 1), cy = min(max(y, 0), mh - 1)
          let i = cy * mrow + cx * 4 + 3
          return i < mask.count ? Float(mask[i]) / 255 : 1
        }
        for y in 0..<cropH {
          for x in 0..<cropW {
            let u = (Double(x) + 0.5) / Double(cropW) * Double(mw) - 0.5
            let v = (Double(y) + 0.5) / Double(cropH) * Double(mh) - 0.5
            let x0 = Int(u.rounded(.down)), y0 = Int(v.rounded(.down))
            let tx = Float(u - Double(x0)), ty = Float(v - Double(y0))
            func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
            let top = mixf(alphaAt(x0, y0), alphaAt(x0 + 1, y0), tx)
            let bot = mixf(alphaAt(x0, y0 + 1), alphaAt(x0 + 1, y0 + 1), tx)
            work[(y * cropW + x) * 4 + 3] *= mixf(top, bot, ty)
          }
        }
      }
    }

    // Premultiply (CG contexts are premultiplied) + make the extended-sRGB
    // image, then the existing PQ HEIC encoder.
    for i in stride(from: 0, to: work.count, by: 4) {
      let a = work[i + 3]
      if a < 1 {
        work[i] *= a; work[i + 1] *= a; work[i + 2] *= a
      }
    }
    var outImage: CGImage? = nil
    work.withUnsafeMutableBytes { p in
      if let ctx = CGContext(
        data: p.baseAddress, width: cropW, height: cropH, bitsPerComponent: 32,
        bytesPerRow: cropW * 16, space: ext, bitmapInfo: floatInfo) {
        outImage = ctx.makeImage()
      }
    }
    guard let outImage else { return nil }
    return ScreenCapturer.encodeHeic(outImage)
  }

  private static func m0MaskData(_ args: [String: Any]) -> FlutterStandardTypedData? {
    args["mask"] as? FlutterStandardTypedData
  }
}
