import AVFoundation
import Cocoa
import CoreGraphics
import CoreImage
import FlutterMacOS
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - LiveFrameSource

/// Live pixels for the live-select loupe: a minimal SCStream of one display
/// (BGRA, native res) that only retains the LATEST frame. The frozen overlay's
/// loupe reads its frozen image; a live session has no pixels to read without
/// a stream. The overlay windows are excluded so the loupe shows TRUE screen
/// pixels (not the dim veil). Runs only while a live-select session is up.
final class LiveFrameSource: NSObject, SCStreamOutput, SCStreamDelegate {
  private var stream: SCStream?
  private let lock = NSLock()
  private var latest: CVPixelBuffer?

  /// Starts the stream; failures are silent (the loupe just stays empty).
  func start(displayID: CGDirectDisplayID, excludingWindowNumbers: [Int]) {
    Task { @MainActor in
      do {
        let content = try await SCShareableContent.current
        guard let d = content.displays.first(where: { $0.displayID == displayID })
        else { return }
        let excluded = content.windows.filter {
          excludingWindowNumbers.contains(Int($0.windowID))
        }
        let scale = NSScreen.screens.first(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber)?.uint32Value == displayID
        })?.backingScaleFactor ?? 2
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(d.width) * scale)
        cfg.height = Int(CGFloat(d.height) * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.colorSpaceName = CGColorSpace.sRGB
        let filter = SCContentFilter(display: d, excludingWindows: excluded)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen,
                              sampleHandlerQueue: DispatchQueue(label: "glimpr.loupe"))
        try await s.startCapture()
        self.stream = s
      } catch {
        // No loupe pixels; selection still works.
      }
    }
  }

  func stop() {
    let s = stream
    stream = nil
    Task { try? await s?.stopCapture() }
    lock.lock()
    latest = nil
    lock.unlock()
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .screen, let pb = CMSampleBufferGetImageBuffer(buffer) else { return }
    lock.lock()
    latest = pb
    lock.unlock()
  }

  /// A span×span RGBA8888 patch centered on the NATIVE pixel
  /// (centerX, centerY) — row-major, ready for Dart's decodeImageFromPixels;
  /// nil while no frame arrived yet. Out-of-bounds cells are transparent.
  func sample(centerX: Int, centerY: Int, span: Int) -> Data? {
    lock.lock()
    let pb = latest
    lock.unlock()
    guard let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let half = span / 2
    var out = Data(count: span * span * 4)
    out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
      guard let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      for row in 0..<span {
        let y = centerY - half + row
        for col in 0..<span {
          let x = centerX - half + col
          let o = (row * span + col) * 4
          if x < 0 || y < 0 || x >= w || y >= h { continue } // stays transparent
          let p = base.advanced(by: y * stride + x * 4)
            .assumingMemoryBound(to: UInt8.self)
          d[o] = p[2] // R (source is BGRA)
          d[o + 1] = p[1] // G
          d[o + 2] = p[0] // B
          d[o + 3] = 255
        }
      }
    }
    return out
  }
}

// MARK: - RecordingChrome

/// Recording chrome design tokens. ONE recording red (#FF453A — the menu-bar
/// design's locked peak; the RECORDING subsystem's accent, the screenshot
/// side keeps the blue accent) and the scrim tone are fixed sRGB; the scrim
/// deliberately stays dark in both appearances (the app's dim-veil
/// convention). Everything else mirrors GlimprTokens
/// (lib/theme/glimpr_theme.dart, the design-system SSOT) as light/dark pairs
/// so the strip reads as the same Aurora chrome as the settings window.
private enum RecordingDesign {
  static let red = NSColor(
    srgbRed: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1)
  static let redHi = NSColor( // gradient highlight (the mark's spark tone)
    srgbRed: 0xFF / 255.0, green: 0x6A / 255.0, blue: 0x60 / 255.0, alpha: 1)
  // UNIFIED chrome dim/scrim (owner 2026-06-14): mirrors Flutter
  // GlimprTokens.scrim — pure black at 40% (0x66/255). Every app mask (settings
  // mask, discard barrier, crop scrim, record-select veil, these recording
  // scrims) shares this one value; theme-independent (dark in both appearances).
  static let scrim = NSColor(
    srgbRed: 0, green: 0, blue: 0, alpha: 0x66 / 255.0)
  static let slate = NSColor( // light-theme ink family base (slate-900)
    srgbRed: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0, alpha: 1)

  /// Two-step destructive-confirm disarm window. Mirrors the Flutter
  /// kConfirmDisarmDuration (glimpr_controls.dart) — keep the two in sync.
  static let confirmDisarmSeconds: TimeInterval = 3

  /// Recording chrome (frame / scrim / strip / countdown) sits ABOVE everything,
  /// including the capture overlay — which uses CGShieldingWindowLevel — so a
  /// recording over a frozen screenshot shows its frame/scrim/strip on TOP
  /// (owner: top-most). The scrim is click-through, so items beneath stay
  /// operable. One above the overlay's shielding level.
  static var windowLevel: NSWindow.Level {
    NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
  }

  /// Appearance-resolving color (NSTextField etc. re-resolve automatically).
  private static func dyn(_ dark: NSColor, _ light: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? dark : light
    }
  }

  // GlimprTokens mirrors (keep in sync with glimpr_theme.dart).
  static let fg1 = dyn(
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96),
    NSColor(srgbRed: 0x14 / 255.0, green: 0x22 / 255.0, blue: 0x3B / 255.0,
            alpha: 1))
  static let fg3 = dyn(
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.46),
    NSColor(srgbRed: 0x64 / 255.0, green: 0x74 / 255.0, blue: 0x8B / 255.0,
            alpha: 1))

  // Near-solid bar background (design guide bar system = GlimprTokens.barBg*):
  // a near-opaque fill laid OVER the vibrancy so the strip is legible like the
  // Flutter bars, with the `.hudWindow` material showing through the ~8%
  // translucency for a frosted texture.
  static let barBg = dyn(
    NSColor(srgbRed: 0x1A / 255.0, green: 0x1E / 255.0, blue: 0x28 / 255.0,
            alpha: 0xB3 / 255.0),
    NSColor(srgbRed: 0xF7 / 255.0, green: 0xF8 / 255.0, blue: 0xFB / 255.0,
            alpha: 0xB3 / 255.0))
  static let barBorder = dyn(
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0x26 / 255.0),
    NSColor(srgbRed: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0,
            alpha: 0x1A / 255.0))
}

/// The region frame: a dim scrim over everything OUTSIDE the recorded region,
/// a 1 px low-opacity red edge with a faint glow, and four viewfinder corner
/// brackets echoing the brand mark. Pure chrome: click-through (the dimmed
/// desktop stays operable) and excluded from the capture filter. The window
/// sits below the menu-bar level and the scrim band stops at the menu-bar
/// line, so the breathing status icon never dims.
private final class RecordingFrameView: NSView {
  private var region: NSRect // view-local
  private var scrimTop: CGFloat // view-local y where the scrim band ends
  private let showScrim: Bool // false = red frame only, no dim (owner setting)

  init(frame: NSRect, region: NSRect, scrimTop: CGFloat, showScrim: Bool = true) {
    self.region = region
    self.scrimTop = scrimTop
    self.showScrim = showScrim
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Re-punch the region (window-follow): the frame tracks a moving window.
  func update(region: NSRect, scrimTop: CGFloat) {
    self.region = region
    self.scrimTop = scrimTop
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current else { return }
    // Scrim with the region punched out. Clipped to the band so a region
    // touching the screen top never gets scrim painted INSIDE itself. Skipped
    // when the user turned the recording dim off — the red frame still draws.
    if showScrim {
      ctx.saveGraphicsState()
      NSBezierPath(rect: NSRect(
        x: 0, y: 0, width: bounds.width, height: scrimTop)).addClip()
      let scrim = NSBezierPath(rect: bounds)
      scrim.append(NSBezierPath(roundedRect: region, xRadius: 3, yRadius: 3))
      scrim.windingRule = .evenOdd
      RecordingDesign.scrim.setFill()
      scrim.fill()
      ctx.restoreGraphicsState()
    }

    // 1 px region edge with a faint red glow.
    ctx.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = RecordingDesign.red.withAlphaComponent(0.18)
    glow.shadowBlurRadius = 13
    glow.set()
    let edge = NSBezierPath(roundedRect: region, xRadius: 3, yRadius: 3)
    edge.lineWidth = 1
    RecordingDesign.red.withAlphaComponent(0.55).setStroke()
    edge.stroke()
    ctx.restoreGraphicsState()

    // Viewfinder corner brackets (the brand mark's corners): 3 pt arms,
    // 22 pt long, rounded outer corner, outer edge 2 pt outside the region.
    let c = region.insetBy(dx: -0.5, dy: -0.5) // bracket stroke centerline
    let arm: CGFloat = 22
    let r: CGFloat = 4.5
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.minX + arm, y: c.maxY)) // top-left
    p.line(to: NSPoint(x: c.minX + r, y: c.maxY))
    p.appendArc(withCenter: NSPoint(x: c.minX + r, y: c.maxY - r), radius: r,
                startAngle: 90, endAngle: 180, clockwise: false)
    p.line(to: NSPoint(x: c.minX, y: c.maxY - arm))
    p.move(to: NSPoint(x: c.maxX - arm, y: c.maxY)) // top-right
    p.line(to: NSPoint(x: c.maxX - r, y: c.maxY))
    p.appendArc(withCenter: NSPoint(x: c.maxX - r, y: c.maxY - r), radius: r,
                startAngle: 90, endAngle: 0, clockwise: true)
    p.line(to: NSPoint(x: c.maxX, y: c.maxY - arm))
    p.move(to: NSPoint(x: c.maxX, y: c.minY + arm)) // bottom-right
    p.line(to: NSPoint(x: c.maxX, y: c.minY + r))
    p.appendArc(withCenter: NSPoint(x: c.maxX - r, y: c.minY + r), radius: r,
                startAngle: 0, endAngle: 270, clockwise: true)
    p.line(to: NSPoint(x: c.maxX - arm, y: c.minY))
    p.move(to: NSPoint(x: c.minX + arm, y: c.minY)) // bottom-left
    p.line(to: NSPoint(x: c.minX + r, y: c.minY))
    p.appendArc(withCenter: NSPoint(x: c.minX + r, y: c.minY + r), radius: r,
                startAngle: 270, endAngle: 180, clockwise: true)
    p.line(to: NSPoint(x: c.minX, y: c.minY + arm))
    p.lineWidth = 3
    RecordingDesign.red.setStroke()
    p.stroke()
  }
}

/// The strip's 11 pt recording dot: a calm breathing glow (1.7 s round trip,
/// in step with the menu-bar breath); a steady glow under reduced motion.
private final class RecordingDotView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = RecordingDesign.red.cgColor
    layer?.cornerRadius = frameRect.height / 2
    layer?.shadowColor = RecordingDesign.red.cgColor
    layer?.shadowOffset = .zero
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      layer?.shadowOpacity = 0.5
      layer?.shadowRadius = 4
    } else {
      layer?.shadowOpacity = 0.55
      layer?.shadowRadius = 6
      let glowOpacity = CABasicAnimation(keyPath: "shadowOpacity")
      glowOpacity.fromValue = 0.0
      glowOpacity.toValue = 0.55
      let glowRadius = CABasicAnimation(keyPath: "shadowRadius")
      glowRadius.fromValue = 1.5
      glowRadius.toValue = 6.0
      let dotOpacity = CABasicAnimation(keyPath: "opacity")
      dotOpacity.fromValue = 0.9
      dotOpacity.toValue = 1.0
      let group = CAAnimationGroup()
      group.animations = [glowOpacity, glowRadius, dotOpacity]
      group.duration = 0.85
      group.autoreverses = true
      group.repeatCount = .infinity
      group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer?.add(group, forKey: "pulse")
    }
  }

  required init?(coder: NSCoder) { fatalError("not used") }
}

/// Strip buttons follow the app's dialog-pair idiom (GhostButton /
/// AccentButton in lib/theme/glimpr_controls.dart): hover changes surface
/// brightness only — NO movement. Stop wears the recording-red accent
/// gradient (the recording subsystem's accent; screenshot keeps blue) with
/// the accent button's white hover wash; Abort is the borderless ghost.
/// 13.5 pt semibold, radius 9, both following the system appearance.
private final class StripButton: NSView {
  enum Kind { case redAccent, ghost }

  private let kind: Kind
  var title: String { didSet { needsDisplay = true } }
  private let action: () -> Void
  // Destructive control: nil = fires immediately; non-nil = two-step confirm
  // (first click arms + shows this danger-coloured label, second click within
  // the confirm window fires, otherwise it disarms) — mirrors Settings'
  // ConfirmGhostButton (timeout = RecordingDesign.confirmDisarmSeconds).
  private let confirmLabel: String?
  private var armed = false {
    didSet {
      needsDisplay = true
      if !armed { disarmTimer?.invalidate(); disarmTimer = nil }
    }
  }
  private var disarmTimer: Timer?
  private let font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
  private var hovered = false { didSet { needsDisplay = true } }
  private var pressed = false { didSet { needsDisplay = true } }

  private var displayTitle: String { armed ? (confirmLabel ?? title) : title }

  init(kind: Kind, title: String, confirmLabel: String? = nil,
       action: @escaping () -> Void) {
    self.kind = kind
    self.title = title
    self.confirmLabel = confirmLabel
    self.action = action
    // Fit the wider of the idle and confirm labels so the swap never clips.
    let text = title.size(withAttributes: [.font: font])
    let labelW = max(text.width,
                     confirmLabel?.size(withAttributes: [.font: font]).width ?? 0)
    let hPad: CGFloat = kind == .redAccent ? 16 : 14
    let iconSpan: CGFloat = kind == .redAccent ? 12 + 7 : 0 // ■ glyph + gap
    super.init(frame: NSRect(
      x: 0, y: 0, width: hPad * 2 + iconSpan + ceil(labelW),
      height: ceil(text.height) + 18))
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  // Buttons act, they never drag the (display-mode movable) strip window.
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
      owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    pressed = false
  }
  override func mouseDown(with event: NSEvent) { pressed = true }
  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    guard inside else { return }
    // Two-step confirm for a destructive control: first click arms (shows the
    // danger confirm label), a second click fires; otherwise it disarms.
    if confirmLabel != nil {
      if !armed {
        armed = true
        disarmTimer = Timer.scheduledTimer(
          withTimeInterval: RecordingDesign.confirmDisarmSeconds,
          repeats: false) { [weak self] _ in
          self?.armed = false
        }
        return
      }
      armed = false
      action()
      return
    }
    action()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let dark = effectiveAppearance
      .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let shape = NSBezierPath(
      roundedRect: bounds, xRadius: 9, yRadius: 9)
    // Content is CENTERED in the box; the label is the confirm label while armed.
    let textW = ceil(displayTitle.size(withAttributes: [.font: font]).width)
    let fg: NSColor
    var textX: CGFloat
    switch kind {
    case .redAccent:
      // AccentButton, recording-red: 135° gradient fill + a faint white wash
      // on hover (reads brighter); pressing dims instead. Text is onAccent.
      NSGradient(colors: [RecordingDesign.red, RecordingDesign.redHi])?
        .draw(in: shape, angle: -45)
      if pressed {
        NSColor.black.withAlphaComponent(0.10).setFill()
        shape.fill()
      } else if hovered {
        NSColor.white.withAlphaComponent(0.12).setFill()
        shape.fill()
      }
      fg = .white
      // ■ stop glyph (12 pt box, the 24-grid icon scaled) + the label, as one
      // centered group.
      let s: CGFloat = 12.0 / 24.0
      let iconY = ((bounds.height - 12) / 2).rounded()
      let contentW = 12 + 7 + textW
      let startX = ((bounds.width - contentW) / 2).rounded()
      let square = NSRect(
        x: startX + 5 * s, y: iconY + 5 * s, width: 14 * s, height: 14 * s)
      fg.setFill()
      NSBezierPath(
        roundedRect: square, xRadius: 2.5 * s, yRadius: 2.5 * s).fill()
      textX = startX + 12 + 7
    case .ghost:
      // GhostButton: borderless; hover paints the nav-hover wash and lifts
      // the label one foreground step (fg3 -> fg2).
      if hovered || pressed {
        let wash = dark
          ? NSColor.white.withAlphaComponent(pressed ? 0.08 : 0.05)
          : RecordingDesign.slate.withAlphaComponent(pressed ? 0.08 : 0.05)
        wash.setFill()
        shape.fill()
      }
      fg = armed
        ? RecordingDesign.red // danger: armed/confirm state
        : (dark
            ? NSColor.white.withAlphaComponent(hovered ? 0.66 : 0.46)
            : (hovered
                ? NSColor(srgbRed: 0x47 / 255.0, green: 0x55 / 255.0,
                          blue: 0x69 / 255.0, alpha: 1) // fg2 light
                : NSColor(srgbRed: 0x64 / 255.0, green: 0x74 / 255.0,
                          blue: 0x8B / 255.0, alpha: 1))) // fg3 light
      textX = ((bounds.width - textW) / 2).rounded()
    }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: fg,
    ]
    let size = displayTitle.size(withAttributes: attrs)
    displayTitle.draw(
      at: NSPoint(x: textX, y: (bounds.height - size.height) / 2),
      withAttributes: attrs)
  }
}

/// The strip's NEAR-SOLID surface (design guide bar system, owner 2026-06-13):
/// bars are not liquid glass — a near-opaque themed fill (RecordingDesign.barBg)
/// is laid OVER a `.hudWindow` vibrancy view so the timer / labels read on any
/// backdrop, with the material showing through the ~8% translucency for a
/// frosted texture. Matches the Flutter bars' near-solid fill so the
/// select-toolbar -> strip transition is consistent.
private final class StripGlassView: NSView {
  private let glass = NSVisualEffectView()
  private let fill = CALayer() // near-opaque tint over the vibrancy
  /// Views recolored to the divider tone on every appearance change.
  var hairlineViews: [NSView] = [] { didSet { applyPalette() } }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    glass.frame = NSRect(origin: .zero, size: frameRect.size)
    glass.material = .hudWindow
    glass.blendingMode = .behindWindow
    glass.state = .active
    glass.wantsLayer = true
    glass.layer?.cornerRadius = 12
    glass.layer?.masksToBounds = true
    glass.layer?.borderWidth = 0.5 // match the Flutter bars' hairline
    // The fill sits ABOVE the vibrancy material (a sublayer of the glass
    // layer) and BELOW the content subviews, which are added later.
    fill.frame = glass.bounds
    fill.cornerRadius = 12
    glass.layer?.addSublayer(fill)
    addSubview(glass)
    applyPalette()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyPalette()
  }

  private func applyPalette() {
    let appearance = effectiveAppearance
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    // Dynamic colors resolve against the CURRENT drawing appearance, so set it
    // before reading .cgColor. No implicit layer animation on a theme flip.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    appearance.performAsCurrentDrawingAppearance {
      fill.backgroundColor = RecordingDesign.barBg.cgColor
      glass.layer?.borderColor = RecordingDesign.barBorder.cgColor
    }
    let divider = dark
      ? NSColor.white.withAlphaComponent(0.08)
      : RecordingDesign.slate.withAlphaComponent(0.08)
    for v in hairlineViews { v.layer?.backgroundColor = divider.cgColor }
    CATransaction.commit()
  }
}

/// The on-screen recording chrome: a frame window (scrim + red edge +
/// viewfinder brackets) around the recorded region (region mode) and a
/// liquid-glass control strip (pulsing dot, timer, file size, Abort/Stop).
/// Display/window modes show only the strip as a draggable HUD. Every window
/// here is listed in the capture filter's exclusions — chrome never appears
/// in the output (chrome vs content: Glimpr's Settings/editor windows DO
/// record).
@MainActor
final class RecordingChrome {
  private var borderWindow: NSWindow?
  private var stripWindow: NSWindow?
  private var scrimWindows: [NSWindow] = [] // dim the OTHER screens (all modes)
  private var otherScreenScrimsActive = false // are the other-screen veils in use?
  private weak var frameView: RecordingFrameView?
  private var chromeScreen: NSScreen?
  private var stripDetached = false // a manual drag detaches the strip from follow
  private var lastStripOrigin: NSPoint? // the last origin WE set (vs a user drag)
  private var stripMoveObserver: NSObjectProtocol?
  private let timerLabel = NSTextField(labelWithString: "00:00")
  private let sizeLabel = NSTextField(labelWithString: "0 MB")
  var onStop: (() -> Void)?
  var onAbort: (() -> Void)?
  var onPause: (() -> Void)?
  var onResume: (() -> Void)?
  private weak var pauseButton: StripButton?
  private var paused = false

  /// Toggle the strip Pause/Resume button label (styling unified in a later
  /// pass; functional only here).
  func setPaused(_ p: Bool) {
    paused = p
    pauseButton?.title = p ? L.s("Resume", "繼續") : L.s("Pause", "暫停")
  }

  /// All chrome windows, for the SCContentFilter exclusion list.
  var windowNumbers: [Int] {
    [borderWindow, stripWindow].compactMap { $0?.windowNumber }
      + scrimWindows.map { $0.windowNumber }
  }

  /// Dim every screen except [target] so it is clear which display is being
  /// recorded — used for ALL record modes (full-display / region / window /
  /// last). Static, full-screen veils on the other displays; shown for the
  /// countdown and the recording alike. Idempotent: it rebuilds the set, so
  /// window-follow can re-call it when the recorded window crosses to another
  /// display (the now-recorded screen un-dims, the vacated one dims).
  func showOtherScreenScrims(excluding target: NSScreen) {
    scrimWindows.forEach { $0.orderOut(nil) }
    scrimWindows.removeAll()
    for screen in NSScreen.screens where screen != target {
      let w = borderlessWindow(
        frame: screen.frame,
        level: RecordingDesign.windowLevel)
      w.ignoresMouseEvents = true
      w.backgroundColor = RecordingDesign.scrim
      w.orderFrontRegardless()
      scrimWindows.append(w)
    }
    otherScreenScrimsActive = true
  }

  /// [regionGlobalBottomLeft] is in Cocoa GLOBAL (bottom-left) coords; nil =
  /// display/window mode (no frame; strip parks bottom-center, draggable).
  func show(regionGlobalBottomLeft: NSRect?, on screen: NSScreen,
            stripHidden: Bool = false, showScrim: Bool = true) {
    chromeScreen = screen
    if let region = regionGlobalBottomLeft {
      let f = borderlessWindow(
        frame: screen.frame,
        level: RecordingDesign.windowLevel)
      f.ignoresMouseEvents = true
      let local = NSRect(
        x: region.minX - screen.frame.minX,
        y: region.minY - screen.frame.minY,
        width: region.width, height: region.height)
      let fv = RecordingFrameView(
        frame: NSRect(origin: .zero, size: screen.frame.size),
        region: local,
        scrimTop: screen.visibleFrame.maxY - screen.frame.minY,
        showScrim: showScrim)
      f.contentView = fv
      frameView = fv
      f.orderFrontRegardless()
      borderWindow = f
    }
    let strip = buildStrip()
    let origin: NSPoint
    if let region = regionGlobalBottomLeft {
      origin = Self.stripOrigin(forRegion: region, on: screen,
                                stripSize: strip.frame.size)
    } else {
      // Display mode: bottom-center, where the selection toolbar lives
      // (owner: same neighborhood as the overlay toolbar).
      origin = NSPoint(
        x: screen.frame.midX - strip.frame.size.width / 2,
        y: screen.frame.minY + 60)
    }
    strip.isMovableByWindowBackground = true // draggable in EVERY mode (owner)
    lastStripOrigin = origin
    strip.setFrameOrigin(origin)
    strip.alphaValue = stripHidden ? 0 : 1
    strip.orderFrontRegardless()
    stripWindow = strip
    // The strip follows the recording frame by default; the FIRST manual drag
    // (a move whose origin we did not set) detaches it so it stays put after.
    stripMoveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification, object: strip, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { // queue: .main -> always on the main actor
        guard let self, let sw = self.stripWindow, let last = self.lastStripOrigin
        else { return }
        if abs(sw.frame.origin.x - last.x) > 0.5
            || abs(sw.frame.origin.y - last.y) > 0.5 {
          self.stripDetached = true
        }
      }
    }
  }

  /// Strip origin for the region/window case: bottom-CENTER of the region
  /// (owner: same "下方置中" rule as display mode). Default is just BELOW the
  /// region (outside); when there is no room below on screen (e.g. a maximized
  /// window whose bottom hugs the screen edge) the strip tucks just INSIDE the
  /// region's bottom — it NEVER flips to the top. Final clamp keeps it on screen.
  private static func stripOrigin(forRegion region: NSRect, on screen: NSScreen,
                                  stripSize: NSSize) -> NSPoint {
    let vf = screen.visibleFrame
    var x = region.midX - stripSize.width / 2
    var y = region.minY - stripSize.height - 8
    if y < vf.minY + 4 { y = region.minY + 8 } // no room below -> tuck inside, not above
    x = min(max(vf.minX + 4, x), vf.maxX - stripSize.width - 4)
    y = min(max(vf.minY + 4, y), vf.maxY - stripSize.height - 4)
    return NSPoint(x: x, y: y)
  }

  /// Window-follow: move the frame + scrim to track a moving window (same
  /// Cocoa-global region coords as show). The strip follows too BY DEFAULT, but
  /// stops once the user has dragged it (stripDetached). Single-display follow;
  /// if the window crosses to another display the frame stays on its screen.
  func reframe(regionGlobalBottomLeft region: NSRect, on screen: NSScreen) {
    if let bw = borderWindow, let fv = frameView {
      if screen != chromeScreen {
        bw.setFrame(screen.frame, display: false)
        fv.frame = NSRect(origin: .zero, size: screen.frame.size)
        chromeScreen = screen
        // Re-home the other-screen veils onto the display the window just left.
        if otherScreenScrimsActive { showOtherScreenScrims(excluding: screen) }
      }
      let local = NSRect(
        x: region.minX - screen.frame.minX,
        y: region.minY - screen.frame.minY,
        width: region.width, height: region.height)
      fv.update(region: local,
                scrimTop: screen.visibleFrame.maxY - screen.frame.minY)
    }
    // The strip trails the frame until the user grabs it (the first manual drag
    // sets stripDetached, after which it stays where they left it).
    if !stripDetached, let sw = stripWindow {
      let origin = Self.stripOrigin(forRegion: region, on: screen,
                                    stripSize: sw.frame.size)
      lastStripOrigin = origin
      sw.setFrameOrigin(origin)
    }
  }

  /// Reveal/hide just the control strip; the frame + scrim stay put. Used so
  /// the strip appears only when recording begins (after a countdown).
  func setStripHidden(_ hidden: Bool) {
    stripWindow?.alphaValue = hidden ? 0 : 1
  }

  func update(duration: CMTime, detail: String) {
    let s = Int(duration.seconds.rounded(.down))
    timerLabel.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
    sizeLabel.stringValue = detail
  }

  func dismiss() {
    if let o = stripMoveObserver { NotificationCenter.default.removeObserver(o) }
    stripMoveObserver = nil
    stripDetached = false
    lastStripOrigin = nil
    borderWindow?.orderOut(nil)
    stripWindow?.orderOut(nil)
    scrimWindows.forEach { $0.orderOut(nil) }
    borderWindow = nil
    stripWindow = nil
    scrimWindows = []
  }

  private func borderlessWindow(frame: NSRect, level: NSWindow.Level) -> NSWindow {
    let w = NSWindow(
      contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.level = level
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    w.hasShadow = false
    w.isReleasedWhenClosed = false
    return w
  }

  private func buildStrip() -> NSWindow {
    // Aurora glass bar (height matches the editor's crop confirm bar):
    // pulsing record dot · mono timer (fg1) · file size (fg3) · divider ·
    // ghost Abort · recording-red accent Stop.
    let height: CGFloat = 52

    let dot = RecordingDotView(
      frame: NSRect(x: 0, y: 0, width: 11, height: 11))

    timerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    timerLabel.textColor = RecordingDesign.fg1
    sizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    sizeLabel.textColor = RecordingDesign.fg3
    timerLabel.stringValue = "00:00"
    sizeLabel.stringValue = "0.0 MB"
    timerLabel.sizeToFit()
    sizeLabel.sizeToFit()
    // Reserve a fixed readout width so a growing value (large MB, or a 5-digit
    // GIF frame count) never overflows into the divider.
    let readoutFont = sizeLabel.font
      ?? .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    sizeLabel.frame.size.width = ceil(max(
      ("9999.9 MB" as NSString).size(withAttributes: [.font: readoutFont]).width,
      ("99999 幀" as NSString).size(withAttributes: [.font: readoutFont]).width))
    sizeLabel.alignment = .right // value hugs the divider as it grows

    let sep = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
    sep.wantsLayer = true

    let pause = StripButton(
      kind: .ghost, title: L.s("Pause", "暫停")
    ) { [weak self] in
      guard let self else { return }
      if self.paused { self.onResume?() } else { self.onPause?() }
    }
    pauseButton = pause
    // Widen ONLY the pause button to fit the wider Resume label so the title
    // swap never clips; abort/finish keep their natural width (owner: do not
    // pad abort/pause out to Finish's width).
    let bf = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    let resumeExtra = max(0, ceil(
      L.s("Resume", "繼續").size(withAttributes: [.font: bf]).width
        - L.s("Pause", "暫停").size(withAttributes: [.font: bf]).width))
    if resumeExtra > 0 {
      var f = pause.frame
      f.size.width += resumeExtra
      pause.frame = f
    }
    // Abort is destructive -> two-step confirm (first click arms a danger
    // "Confirm?" label, a second click within the confirm window aborts).
    let abort = StripButton(
      kind: .ghost, title: L.s("Abort", "中止"),
      confirmLabel: L.s("Confirm?", "確認？")
    ) { [weak self] in self?.onAbort?() }
    let stop = StripButton(
      kind: .redAccent, title: L.s("Finish", "完成")
    ) { [weak self] in self?.onStop?() }

    // Sequential row layout; widths land before the container exists so the
    // window is sized to fit.
    var x: CGFloat = 16
    func place(_ v: NSView, gapAfter: CGFloat) {
      var f = v.frame
      f.origin = NSPoint(x: x, y: ((height - f.height) / 2).rounded())
      v.frame = f
      x = f.maxX + gapAfter
    }
    place(dot, gapAfter: 14)
    place(timerLabel, gapAfter: 14)
    place(sizeLabel, gapAfter: 16)
    place(sep, gapAfter: 16)
    place(pause, gapAfter: 10)
    place(abort, gapAfter: 10) // dialog-pair spacing (confirm_dialog.dart)
    place(stop, gapAfter: 12)

    let container = StripGlassView(
      frame: NSRect(x: 0, y: 0, width: x, height: height))
    for v in [dot, timerLabel, sizeLabel, sep, pause, abort, stop] {
      container.addSubview(v)
    }
    container.hairlineViews = [sep]

    let w = borderlessWindow(frame: container.frame, level: RecordingDesign.windowLevel)
    w.contentView = container
    return w
  }
}

// MARK: - RecordingController

/// AVAssetWriter wrapper (engine B): one VFR video track + up to two audio
/// tracks (system / mic), fed by RecordingSink off the capture queue. We own
/// the presentation timeline so pause is simply a gap we never write — no
/// SCRecordingOutput, no FFmpeg, no temp/remux. Replaces the v1 black-box
/// recorder to enable pause/resume, fixed-duration and direct GIF.
@available(macOS 15.0, *)
final class RecordingWriter {
  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private var systemInput: AVAssetWriterInput?
  private var micInput: AVAssetWriterInput?
  private(set) var started = false

  init(url: URL, width: Int, height: Int, hevc: Bool,
       systemAudio: Bool, microphone: Bool) throws {
    try? FileManager.default.removeItem(at: url)
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
    ]
    videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = true
    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.canAdd(videoInput) else {
      throw RecordingController.RecordingError.message("cannot add video input")
    }
    writer.add(videoInput)

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: 2,
      AVSampleRateKey: 48_000,
      AVEncoderBitRateKey: 128_000,
    ]
    func addAudio() -> AVAssetWriterInput? {
      let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      a.expectsMediaDataInRealTime = true
      guard writer.canAdd(a) else { return nil }
      writer.add(a)
      return a
    }
    if systemAudio { systemInput = addAudio() }
    if microphone { micInput = addAudio() }
  }

  func start() {
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    started = true
  }

  func appendVideo(_ pb: CVPixelBuffer, at pts: CMTime) {
    guard started, videoInput.isReadyForMoreMediaData else { return }
    adaptor.append(pb, withPresentationTime: pts)
  }

  func appendSystem(_ sb: CMSampleBuffer) {
    guard started, let a = systemInput, a.isReadyForMoreMediaData else { return }
    a.append(sb)
  }

  func appendMic(_ sb: CMSampleBuffer) {
    guard started, let a = micInput, a.isReadyForMoreMediaData else { return }
    a.append(sb)
  }

  func finish() async -> Bool {
    guard started else { return false }
    videoInput.markAsFinished()
    systemInput?.markAsFinished()
    micInput?.markAsFinished()
    await writer.finishWriting()
    return writer.status == .completed
  }

  func cancel() {
    if started { writer.cancelWriting() }
    try? FileManager.default.removeItem(at: writer.outputURL)
  }
}

/// A capture sink the controller can drive uniformly whether the output is an
/// mp4 (RecordingSink + AVAssetWriter) or a GIF (GifSink + ImageIO).
@available(macOS 15.0, *)
protocol RecordingSinkBase: SCStreamOutput {
  func setPaused(_ p: Bool)
  var elapsedSeconds: Double { get } // recorded media time, un-paused
  var frameCount: Int { get }        // GIF frames so far (0 for mp4)
  func finish() async -> Bool        // finalize the output file
  func cancel()                      // discard a partial output
}

/// Off-main capture sink: receives SCStream video + audio sample buffers on a
/// single serial queue and appends them to the RecordingWriter on a 0-based,
/// pause-aware timeline (VFR video — each frame appended once with its rebased
/// PTS; a static screen simply holds the last frame). The first .screen frame
/// establishes the session.
@available(macOS 15.0, *)
final class RecordingSink: NSObject, RecordingSinkBase {
  private let writer: RecordingWriter
  private let lock = NSLock()
  private var sessionStart: CMTime?
  private var pausedAccum = CMTime.zero
  private var pauseStart: CMTime?
  private var paused = false
  private var lastElapsed = CMTime.zero
  /// Fired once on the first frame (session established).
  var onStarted: (() -> Void)?

  init(writer: RecordingWriter) { self.writer = writer }

  /// Recorded media time so far (un-paused), seconds — strip + auto-stop.
  var elapsedSeconds: Double {
    lock.lock(); defer { lock.unlock() }
    return max(0, lastElapsed.seconds)
  }

  func setPaused(_ p: Bool) {
    lock.lock(); paused = p; lock.unlock()
  }

  var frameCount: Int { 0 } // mp4 shows file size instead
  func finish() async -> Bool { await writer.finish() }
  func cancel() { writer.cancel() }

  func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard CMSampleBufferDataIsReady(sb) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)

    lock.lock()
    if sessionStart == nil {
      guard type == .screen, CMSampleBufferGetImageBuffer(sb) != nil else {
        lock.unlock(); return
      }
      sessionStart = pts
      writer.start()
      let cb = onStarted
      lock.unlock()
      cb?()
      lock.lock()
    }
    let start = sessionStart ?? pts
    if paused {
      if pauseStart == nil { pauseStart = pts }
      lock.unlock(); return
    } else if let ps = pauseStart {
      pausedAccum = pausedAccum + (pts - ps)
      pauseStart = nil
    }
    let rebased = pts - start - pausedAccum
    if type == .screen { lastElapsed = rebased }
    lock.unlock()

    switch type {
    case .screen:
      if let pb = CMSampleBufferGetImageBuffer(sb) {
        writer.appendVideo(pb, at: rebased)
      }
    case .audio:
      if let r = Self.retimed(sb, to: rebased) { writer.appendSystem(r) }
    case .microphone:
      if let r = Self.retimed(sb, to: rebased) { writer.appendMic(r) }
    @unknown default:
      break
    }
  }

  /// Copy an audio sample buffer with its PTS rebased to [to] (constant offset).
  private static func retimed(_ sb: CMSampleBuffer, to target: CMTime) -> CMSampleBuffer? {
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(
      sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    guard count > 0 else { return nil }
    var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(
      sb, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
    let offset = CMSampleBufferGetPresentationTimeStamp(sb) - target
    for i in 0..<timings.count where timings[i].presentationTimeStamp.isValid {
      timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - offset
    }
    var out: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sb,
      sampleTimingEntryCount: count, sampleTimingArray: &timings,
      sampleBufferOut: &out)
    return out
  }
}

/// ImageIO animated-GIF encoder (engine B direct-GIF path): frames are added
/// incrementally as they arrive and finalized on stop. 256-color quantization
/// is ImageIO's; loop count 0 = infinite. No mp4, no FFmpeg.
final class GifWriter {
  private let url: URL
  private let dest: CGImageDestination?
  private var frames = 0

  init(url: URL, loop: Int = 0) {
    self.url = url
    try? FileManager.default.removeItem(at: url)
    dest = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.gif.identifier as CFString, 0, nil)
    if let dest {
      CGImageDestinationSetProperties(dest, [
        kCGImagePropertyGIFDictionary: [
          kCGImagePropertyGIFLoopCount: loop,
        ],
      ] as CFDictionary)
    }
  }

  func add(_ image: CGImage, delay: Double) {
    guard let dest else { return }
    CGImageDestinationAddImage(dest, image, [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: delay,
        kCGImagePropertyGIFUnclampedDelayTime: delay,
      ],
    ] as CFDictionary)
    frames += 1
  }

  var frameCount: Int { frames }

  func finish() -> Bool {
    guard let dest, frames > 0 else { return false }
    return CGImageDestinationFinalize(dest)
  }

  func cancel() {
    try? FileManager.default.removeItem(at: url)
  }
}

/// GIF capture sink: samples the live screen at the GIF frame rate, downscales
/// each frame to the GIF max dimension, and feeds GifWriter. Pause-aware and
/// reports recorded media time like RecordingSink, so the controller drives it
/// the same way. GIF has no audio, so only the .screen output is attached.
@available(macOS 15.0, *)
final class GifSink: NSObject, RecordingSinkBase {
  private let gif: GifWriter
  private let frameInterval: Double
  private let maxLongSide: CGFloat
  private let ciContext = CIContext()
  private let lock = NSLock()
  private var sessionStart: CMTime?
  private var pausedAccum = CMTime.zero
  private var pauseStart: CMTime?
  private var paused = false
  private var lastElapsed = CMTime.zero
  private var lastAddSeconds = -1.0
  var onStarted: (() -> Void)?

  init(gif: GifWriter, gifFps: Int, maxLongSide: Int) {
    self.gif = gif
    self.frameInterval = 1.0 / Double(max(1, gifFps))
    self.maxLongSide = CGFloat(maxLongSide)
  }

  var elapsedSeconds: Double {
    lock.lock(); defer { lock.unlock() }
    return max(0, lastElapsed.seconds)
  }

  func setPaused(_ p: Bool) { lock.lock(); paused = p; lock.unlock() }
  var frameCount: Int { gif.frameCount }
  func finish() async -> Bool { gif.finish() }
  func cancel() { gif.cancel() }

  func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .screen, CMSampleBufferDataIsReady(sb),
          let pb = CMSampleBufferGetImageBuffer(sb) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)

    lock.lock()
    if sessionStart == nil {
      sessionStart = pts
      let cb = onStarted
      lock.unlock(); cb?(); lock.lock()
    }
    let start = sessionStart ?? pts
    if paused {
      if pauseStart == nil { pauseStart = pts }
      lock.unlock(); return
    } else if let ps = pauseStart {
      pausedAccum = pausedAccum + (pts - ps); pauseStart = nil
    }
    let elapsed = (pts - start - pausedAccum).seconds
    lastElapsed = CMTime(seconds: elapsed, preferredTimescale: 600)
    if lastAddSeconds >= 0, elapsed - lastAddSeconds < frameInterval {
      lock.unlock(); return
    }
    lastAddSeconds = elapsed
    lock.unlock()

    if let cg = downscaled(pb) { gif.add(cg, delay: frameInterval) }
  }

  private func downscaled(_ pb: CVPixelBuffer) -> CGImage? {
    let ci = CIImage(cvPixelBuffer: pb)
    let longSide = max(ci.extent.width, ci.extent.height)
    let scale = longSide > maxLongSide ? maxLongSide / longSide : 1
    let out = scale < 1
      ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
    return ciContext.createCGImage(out, from: out.extent)
  }
}

/// A pre-recording countdown overlay (engine B start delay): a big number
/// centered on the target (region center, else display center) counting down
/// to 0 before capture starts. Clicking it — or Stop/Abort — cancels (no file).
/// Styling is unified in a later pass; this is functional.
@available(macOS 15.0, *)
@MainActor
final class CountdownHUD {
  private var window: NSWindow?
  private var timer: Timer?
  private var remaining = 0
  private var continuation: CheckedContinuation<Bool, Never>?
  private let label = NSTextField(labelWithString: "")

  /// Returns true to proceed with recording, false if cancelled.
  func run(seconds: Int, on screen: NSScreen, center: NSPoint) async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      continuation = cont
      remaining = seconds
      present(on: screen, center: center)
      update()
      let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
        [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.remaining -= 1
          if self.remaining <= 0 { self.finish(true) } else { self.update() }
        }
      }
      RunLoop.main.add(t, forMode: .common)
      timer = t
    }
  }

  func cancel() { finish(false) }

  /// Recenter on a (moving window's) center — used by the window-follow timer
  /// so the countdown stays centered in the frame as the window moves.
  func recenter(center: NSPoint) {
    guard let w = window else { return }
    w.setFrameOrigin(NSPoint(x: center.x - w.frame.width / 2,
                             y: center.y - w.frame.height / 2))
  }

  private func finish(_ proceed: Bool) {
    timer?.invalidate(); timer = nil
    window?.orderOut(nil); window = nil
    let c = continuation; continuation = nil
    c?.resume(returning: proceed)
  }

  private func update() { label.stringValue = "\(max(0, remaining))" }

  private func present(on screen: NSScreen, center: NSPoint) {
    let size: CGFloat = 132
    let frame = NSRect(x: center.x - size / 2, y: center.y - size / 2,
                       width: size, height: size)
    let w = NSWindow(contentRect: frame, styleMask: .borderless,
                     backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.level = RecordingDesign.windowLevel
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    w.hasShadow = false
    w.isReleasedWhenClosed = false
    let view = CountdownView(frame: NSRect(origin: .zero, size: frame.size))
    view.onClick = { [weak self] in self?.cancel() }
    label.frame = NSRect(x: 0, y: (size - 92) / 2 + 12, width: size, height: 92)
    label.alignment = .center
    label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .bold)
    label.textColor = .white
    view.addSubview(label)
    // Hint: the HUD itself is the only cancel target.
    let hint = NSTextField(labelWithString: L.s("Click to cancel", "點此取消"))
    hint.frame = NSRect(x: 0, y: 16, width: size, height: 16)
    hint.alignment = .center
    hint.font = .systemFont(ofSize: 11, weight: .medium)
    hint.textColor = NSColor.white.withAlphaComponent(0.65)
    view.addSubview(hint)
    w.contentView = view
    w.orderFrontRegardless()
    window = w
  }
}

private final class CountdownView: NSView {
  var onClick: (() -> Void)?
  override func draw(_ dirtyRect: NSRect) {
    let r = bounds.insetBy(dx: 4, dy: 4)
    NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.92).setFill()
    NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26).fill()
  }
  override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Owns one recording session (engine B): an SCStream feeding RecordingSink ->
/// RecordingWriter (AVAssetWriter). All recording native code lives behind the
/// `glimpr/record` seam — the existing capture path is untouched.
@available(macOS 15.0, *)
@MainActor
final class RecordingController: NSObject, SCStreamDelegate {
  struct Spec {
    let mode: String // region | window | display | lastRegion
    let displayID: CGDirectDisplayID?
    let rect: CGRect? // display-local top-left logical points
    let windowID: CGWindowID?
    let fps: Int
    let hevc: Bool
    let gif: Bool // true = direct GIF (no mp4, no audio)
    let showsCursor: Bool
    let showScrim: Bool // dim outside the region + other displays (red frame stays)
    let systemAudio: Bool
    let microphone: Bool
    let maxDuration: Int // seconds; 0 = off
    let countdown: Int // seconds; 0 = off (start delay)
    let outputPath: String
  }

  private(set) var isRecording = false
  private var stream: SCStream?
  // Window mode only: a second, display-scoped stream that supplies SYSTEM
  // audio (the window stream's own audio would be the target app's only).
  private var audioStream: SCStream?
  private var sink: RecordingSinkBase?
  private var chrome: RecordingChrome?
  private var tick: Timer?
  private var followTimer: Timer? // window-mode frame follow (~30 Hz)
  private var outputPath: String?
  private var abortRequested = false
  private var paused = false
  private var isGif = false
  private var maxDuration = 0 // seconds; 0 = off (auto-stop disabled)
  private var countdownHUD: CountdownHUD?
  private let sampleQueue = DispatchQueue(label: "glimpr.record.samples")
  private var events: (String, Any?) -> Void
  /// (active, graceful) — graceful=false on abort/failure so the menu-bar
  /// icon snaps back instead of easing (design: the dropped color confirms
  /// nothing was kept).
  var onStateChange: ((Bool, Bool) -> Void)?
  /// Paused-state hook for the menu-bar Pause/Resume item.
  var onPauseChange: ((Bool) -> Void)?

  init(events: @escaping (String, Any?) -> Void) {
    self.events = events
  }

  func start(_ spec: Spec) async {
    guard !isRecording, stream == nil else {
      events("onRecordFailed", ["message": "already recording"])
      return
    }
    do {
      // Shareable content is fetched lazily per branch: the region/display path
      // shows its chrome (the mask) FIRST and fetches AFTER, so there is no
      // mask-less flash between the record-select picker tearing down and the
      // recording chrome appearing. Window mode resolves its SCWindow up front
      // (and has no picker), so it fetches first as before.
      var content: SCShareableContent?

      let filter: SCContentFilter
      var chromeRegionGlobal: NSRect? // Cocoa global bottom-left, for chrome
      var screen: NSScreen
      let scale: CGFloat
      // The fixed rect + display reported back as the recorded region, so the
      // control engine can remember it for "Record Last Region" (every mode,
      // matching the screenshot side). Display-local top-left logical points.
      var reportedDisplayID: CGDirectDisplayID = 0
      var reportedRect = CGRect.zero

      if spec.mode == "window", let wid = spec.windowID {
        let scc = try await SCShareableContent.current
        content = scc
        guard let scWindow = scc.windows.first(where: { $0.windowID == wid })
        else { throw RecordingError.message("window not found") }
        filter = SCContentFilter(desktopIndependentWindow: scWindow)
        scale = CGFloat(filter.pointPixelScale)
        // Frame + scrim around the window (owner: show the recording range like
        // region mode); it follows the window during recording. No exclusion
        // needed — the desktopIndependentWindow filter records only the window,
        // so chrome on the desktop can never appear in the output.
        let wrect = Self.windowCocoaRect(wid)
          ?? NSRect(x: 0, y: 0, width: 200, height: 200)
        chromeRegionGlobal = wrect
        screen = NSScreen.screens.first(where: { $0.frame.intersects(wrect) })
          ?? NSScreen.main ?? NSScreen.screens[0]
        reportedDisplayID = (screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        // The window's display-local rect at start. The recording follows the
        // window, but "last region" remembers this fixed rect (parity with the
        // screenshot window capture).
        reportedRect = CGRect(
          x: wrect.minX - screen.frame.minX,
          y: screen.frame.maxY - wrect.maxY,
          width: wrect.width, height: wrect.height)
        let c = RecordingChrome()
        c.show(regionGlobalBottomLeft: wrect, on: screen,
               stripHidden: spec.countdown > 0, showScrim: spec.showScrim)
        // Dim the OTHER screens (the recorded window lives on one screen). The
        // window-follow refreshes this set if the window crosses displays.
        if spec.showScrim { c.showOtherScreenScrims(excluding: screen) }
        chrome = c
        // Follow from now so the frame (and the countdown HUD) tracks the
        // window during the countdown too, not only once recording begins.
        startWindowFollow(windowID: wid)
      } else {
        // Mask FIRST (needs no SCK): resolve the screen from NSScreen and the
        // region from spec.rect, show the recording chrome, THEN fetch shareable
        // content. The chrome appears the instant the record-select picker tears
        // down — closing the mask-less flash on the picker -> record transition.
        let displayID = spec.displayID ?? Self.cursorDisplayID()
        guard let nsScreen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                  as? NSNumber)?.uint32Value == displayID
              })
        else { throw RecordingError.message("display not found") }
        screen = nsScreen
        scale = nsScreen.backingScaleFactor
        reportedDisplayID = displayID
        // region/lastRegion: the requested rect; display: the whole display.
        reportedRect = spec.rect ?? CGRect(
          x: 0, y: 0, width: nsScreen.frame.width, height: nsScreen.frame.height)

        let c = RecordingChrome()
        if let r = spec.rect {
          // top-left display-local -> Cocoa global bottom-left
          let global = NSRect(
            x: nsScreen.frame.minX + r.minX,
            y: nsScreen.frame.maxY - r.maxY,
            width: r.width, height: r.height)
          chromeRegionGlobal = global
        }
        c.show(regionGlobalBottomLeft: chromeRegionGlobal, on: nsScreen,
               stripHidden: spec.countdown > 0, showScrim: spec.showScrim)
        chrome = c
        if spec.showScrim {
          // Dim every OTHER screen (owner) so it is clear which display is being
          // recorded — for full-display AND region / last-region. They sit on
          // other displays, so they are never part of this display's capture.
          // Skipped when the user turned the recording dim off.
          c.showOtherScreenScrims(excluding: nsScreen)
        }
        // Content fetched AFTER the chrome exists, so the exclusion list catches
        // the chrome windows (chrome never records; Glimpr content windows do).
        let scc = try await SCShareableContent.current
        content = scc
        guard let scDisplay = scc.displays.first(
          where: { $0.displayID == displayID })
        else { throw RecordingError.message("display not found") }
        let excludedNumbers = c.windowNumbers
        let excluded = scc.windows.filter {
          excludedNumbers.contains(Int($0.windowID))
        }
        filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
      }

      // Countdown start delay: the frame + scrim stay visible (region) but the
      // control strip is hidden until recording begins. Only the HUD cancels —
      // the frame/scrim ignores mouse, so clicking the mask does nothing.
      if spec.countdown > 0 {
        let center = chromeRegionGlobal.map { NSPoint(x: $0.midX, y: $0.midY) }
          ?? NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let hud = CountdownHUD()
        countdownHUD = hud
        let proceed = await hud.run(
          seconds: spec.countdown, on: screen, center: center)
        countdownHUD = nil
        if !proceed {
          followTimer?.invalidate()
          followTimer = nil
          chrome?.dismiss()
          chrome = nil
          events("onRecordAborted", nil)
          return
        }
        chrome?.setStripHidden(false)
      }

      let cfg = SCStreamConfiguration()
      cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(spec.fps))
      cfg.showsCursor = spec.showsCursor
      cfg.colorSpaceName = CGColorSpace.sRGB
      if spec.mode == "window" {
        let content = filter.contentRect
        cfg.width = Self.even(Int((content.width * scale).rounded()))
        cfg.height = Self.even(Int((content.height * scale).rounded()))
        cfg.scalesToFit = true
      } else if let r = spec.rect {
        cfg.sourceRect = r
        cfg.width = Self.even(Int((r.width * scale).rounded()))
        cfg.height = Self.even(Int((r.height * scale).rounded()))
      } else {
        cfg.width = Self.even(Int(screen.frame.width * scale))
        cfg.height = Self.even(Int(screen.frame.height * scale))
      }
      // Audio: region/display/lastRegion mix it into this (display-scoped)
      // stream. Window mode does NOT — a single-window filter captures only the
      // target app's audio, not the whole system; it gets a separate
      // display-scoped audio stream below so every mode records system audio.
      let windowMode = spec.mode == "window"
      if !windowMode {
        if spec.systemAudio {
          cfg.capturesAudio = true
          cfg.excludesCurrentProcessAudio = true
        }
        if spec.microphone {
          cfg.captureMicrophone = true
        }
      }

      let sk: RecordingSinkBase
      if spec.gif {
        // GIF: no AVAssetWriter, no audio; sample at the GIF frame rate.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        let g = GifWriter(url: URL(fileURLWithPath: spec.outputPath))
        let gs = GifSink(gif: g, gifFps: 15, maxLongSide: 800)
        gs.onStarted = { PerfLog.mark("recordFirstFrame") }
        sk = gs
      } else {
        let w = try RecordingWriter(
          url: URL(fileURLWithPath: spec.outputPath),
          width: cfg.width, height: cfg.height, hevc: spec.hevc,
          systemAudio: spec.systemAudio, microphone: spec.microphone)
        let rs = RecordingSink(writer: w)
        rs.onStarted = { PerfLog.mark("recordFirstFrame") }
        sk = rs
      }

      let s = SCStream(filter: filter, configuration: cfg, delegate: self)
      try s.addStreamOutput(sk, type: .screen, sampleHandlerQueue: sampleQueue)
      if !spec.gif && !windowMode {
        if spec.systemAudio {
          try s.addStreamOutput(sk, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if spec.microphone {
          try s.addStreamOutput(sk, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
      }
      try await s.startCapture()

      // Window mode + audio: SYSTEM audio comes from a second, display-scoped
      // stream feeding the SAME sink (it routes by sample type, and the shared
      // serial sample queue keeps appends ordered). Both streams' PTS ride one
      // host clock, so audio rebases onto the video session and stays in sync.
      if !spec.gif && windowMode && (spec.systemAudio || spec.microphone),
         let scc = content,
         let aDisplay = scc.displays.first(where: {
           $0.displayID == reportedDisplayID
         }) {
        let aCfg = SCStreamConfiguration()
        aCfg.minimumFrameInterval = CMTime(value: 1, timescale: 1) // video unused
        aCfg.width = 2
        aCfg.height = 2
        if spec.systemAudio {
          aCfg.capturesAudio = true
          aCfg.excludesCurrentProcessAudio = true
        }
        if spec.microphone { aCfg.captureMicrophone = true }
        let aStream = SCStream(
          filter: SCContentFilter(display: aDisplay, excludingWindows: []),
          configuration: aCfg, delegate: self)
        if spec.systemAudio {
          try aStream.addStreamOutput(sk, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if spec.microphone {
          try aStream.addStreamOutput(sk, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        try await aStream.startCapture()
        audioStream = aStream
      }

      chrome?.onStop = { [weak self] in Task { await self?.stop() } }
      chrome?.onAbort = { [weak self] in Task { await self?.abort() } }
      chrome?.onPause = { [weak self] in Task { @MainActor in self?.pause() } }
      chrome?.onResume = { [weak self] in Task { @MainActor in self?.resume() } }

      stream = s
      sink = sk
      outputPath = spec.outputPath
      maxDuration = spec.maxDuration
      isGif = spec.gif
      abortRequested = false
      paused = false
      isRecording = true
      onStateChange?(true, true)
      startTick()
      PerfLog.mark("recordStart mode=\(spec.mode)")
      events("onRecordStarted", [
        "displayId": Int(reportedDisplayID),
        "x": Double(reportedRect.minX), "y": Double(reportedRect.minY),
        "w": Double(reportedRect.width), "h": Double(reportedRect.height),
      ])
    } catch {
      cleanupSession(graceful: false)
      events("onRecordFailed", ["message": "\(error)"])
    }
  }

  func stop() async {
    if let hud = countdownHUD { hud.cancel(); return } // cancel a pending start
    guard isRecording else { return }
    isRecording = false // block double-stops
    let s = stream
    let a = audioStream
    stream = nil
    audioStream = nil
    try? await s?.stopCapture()
    try? await a?.stopCapture()
    if abortRequested {
      sink?.cancel()
      finalize(result: .aborted)
    } else {
      // GIF finalize encodes every accumulated frame, so flag a processing
      // phase first; the completion sound + after-record flow fire only after
      // onRecordFinished (i.e. after the GIF is fully written).
      if isGif { events("onRecordProcessing", nil) }
      let ok = await (sink?.finish() ?? false)
      finalize(result: ok ? .finished : .failed("encoder did not complete"))
    }
  }

  func abort() async {
    if let hud = countdownHUD { hud.cancel(); return }
    abortRequested = true
    await stop()
  }

  func pause() {
    guard isRecording, !paused else { return }
    paused = true
    sink?.setPaused(true)
    chrome?.setPaused(true)
    onPauseChange?(true)
    events("onRecordPaused", nil)
  }

  func resume() {
    guard isRecording, paused else { return }
    paused = false
    sink?.setPaused(false)
    chrome?.setPaused(false)
    onPauseChange?(false)
    events("onRecordResumed", nil)
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    Task { @MainActor in
      guard self.isRecording else { return } // our own stop already handled it
      self.isRecording = false
      // Either stream erroring fails the session; stop the surviving one too
      // (stopping the already-stopped one is a harmless no-op).
      let v = self.stream
      let a = self.audioStream
      self.stream = nil
      self.audioStream = nil
      try? await v?.stopCapture()
      try? await a?.stopCapture()
      self.sink?.cancel()
      self.finalize(result: .failed("\(error)"))
    }
  }

  private enum Outcome { case finished, aborted, failed(String) }

  private func finalize(result: Outcome) {
    let path = outputPath
    let dur = sink?.elapsedSeconds ?? 0
    let size = currentFileSize()
    let graceful: Bool = { if case .finished = result { return true }; return false }()
    cleanupSession(graceful: graceful)
    switch result {
    case .finished:
      PerfLog.mark("recordEnd ok")
      events("onRecordFinished",
             ["path": path ?? "", "duration": dur, "fileSize": size])
    case .aborted:
      if let p = path { try? FileManager.default.removeItem(atPath: p) }
      PerfLog.mark("recordEnd aborted")
      events("onRecordAborted", nil)
    case .failed(let m):
      if let p = path { try? FileManager.default.removeItem(atPath: p) }
      PerfLog.mark("recordEnd failed")
      events("onRecordFailed", ["message": m])
    }
  }

  private func cleanupSession(graceful: Bool = true) {
    tick?.invalidate()
    tick = nil
    followTimer?.invalidate()
    followTimer = nil
    chrome?.dismiss()
    chrome = nil
    stream = nil
    audioStream = nil
    sink = nil
    outputPath = nil
    isRecording = false
    paused = false
    isGif = false
    onStateChange?(false, graceful)
  }

  private func currentFileSize() -> Int {
    guard let p = outputPath,
          let attrs = try? FileManager.default.attributesOfItem(atPath: p),
          let size = attrs[.size] as? Int
    else { return 0 }
    return size
  }

  private func startTick() {
    tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        guard let self, let sink = self.sink else { return }
        let elapsed = sink.elapsedSeconds
        // GIF buffers until finalize, so its on-disk size is 0 mid-record; show
        // the captured frame count instead. mp4 grows on disk, so show size.
        let detail = self.isGif
          ? "\(sink.frameCount) " + L.s("frames", "幀")
          : String(format: "%.1f MB", Double(self.currentFileSize()) / 1_048_576)
        self.chrome?.update(
          duration: CMTime(seconds: elapsed, preferredTimescale: 600),
          detail: detail)
        // Fixed-duration auto-stop: recorded media time excludes paused time,
        // so a paused take never trips this.
        if self.maxDuration > 0, self.isRecording, !self.paused,
           elapsed >= Double(self.maxDuration) {
          await self.stop()
        }
      }
    }
  }

  private static func even(_ v: Int) -> Int { max(2, v - (v % 2)) }

  /// Poll the recorded window's position ~30 Hz and move the frame + strip to
  /// track it (the owner accepts the cost for an accurate recording-range
  /// frame). Stops with the session.
  private func startWindowFollow(windowID: CGWindowID) {
    let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        // Runs during the countdown AND recording (guard on the chrome, not
        // isRecording), so the frame + HUD track the window the whole time.
        guard let self, let chrome = self.chrome,
              let rect = Self.windowCocoaRect(windowID) else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
          ?? NSScreen.main ?? NSScreen.screens[0]
        chrome.reframe(regionGlobalBottomLeft: rect, on: screen)
        self.countdownHUD?.recenter(center: NSPoint(x: rect.midX, y: rect.midY))
      }
    }
    RunLoop.main.add(t, forMode: .common)
    followTimer = t
  }

  /// A window's on-screen bounds in Cocoa GLOBAL (bottom-left) coords, from the
  /// window server (CG top-left bounds flipped about the main display).
  private static func windowCocoaRect(_ windowID: CGWindowID) -> NSRect? {
    guard let infos = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], windowID) as? [[String: Any]],
          let bounds = infos.first?[kCGWindowBounds as String] as? [String: Any],
          let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else { return nil }
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    return NSRect(x: cg.minX, y: mainH - cg.maxY,
                  width: cg.width, height: cg.height)
  }

  private static func cursorDisplayID() -> CGDirectDisplayID {
    let mouse = NSEvent.mouseLocation
    for screen in NSScreen.screens where NSMouseInRect(mouse, screen.frame, false) {
      if let n = (screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
        return CGDirectDisplayID(n)
      }
    }
    return CGMainDisplayID()
  }

  enum RecordingError: Error { case message(String) }
}

// MARK: - RecordingChannel

/// The `glimpr/record` seam on the CONTROL engine. Dart sends
/// start/stop/abort/isAvailable; native answers with onRecordStarted /
/// onRecordFinished / onRecordFailed / onRecordAborted events. Region mode
/// runs the LiveRegionSelector first, entirely natively.
@MainActor
final class RecordingChannel {
  private let channel: FlutterMethodChannel
  private var controller: Any? // RecordingController, macOS 15+ only
  /// Menu-bar state hook (breathing icon + Stop/Abort items while recording);
  /// the second flag is graceful (false = abort/failure, icon snaps back).
  var onRecordingStateChange: ((Bool, Bool) -> Void)?
  /// Paused-state hook for the menu-bar Pause/Resume item.
  var onRecordingPauseChange: ((Bool) -> Void)?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "glimpr/record", binaryMessenger: messenger)
    // LOCAL DEBUG HOOK — inert unless `defaults write com.howar31.glimpr
    // debugHooks -bool YES`: lets a local CLI drive the selection relay /
    // stop / abort (end-to-end verification without synthetic mouse input).
    // Distributed notifications never leave the machine.
    if UserDefaults.standard.bool(forKey: "debugHooks") {
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.howar31.glimpr.debug.record"),
        object: nil, queue: .main
      ) { [weak self] note in
        guard let json = note.object as? String,
              let data = json.data(using: .utf8),
              let a = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any]
        else { return }
        Task { @MainActor in
          guard let self else { return }
          switch a["action"] as? String {
          case "selection": self.notifySelection(a)
          case "stop": self.stopActive()
          case "abort": self.abortActive()
          default: break
          }
        }
      }
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "isAvailable":
        if #available(macOS 15.0, *) { result(true) } else { result(false) }
      case "start":
        guard #available(macOS 15.0, *) else {
          return result(FlutterError(
            code: "unavailable", message: "needs macOS 15", details: nil))
        }
        let a = (call.arguments as? [String: Any]) ?? [:]
        self.start(args: a)
        result(nil)
      case "stop":
        guard #available(macOS 15.0, *) else { return result(nil) }
        Task { await self.current()?.stop() }
        result(nil)
      case "abort":
        guard #available(macOS 15.0, *) else { return result(nil) }
        Task { await self.current()?.abort() }
        result(nil)
      case "pause":
        if #available(macOS 15.0, *) { self.current()?.pause() }
        result(nil)
      case "resume":
        if #available(macOS 15.0, *) { self.current()?.resume() }
        result(nil)
      case "isRecording":
        if #available(macOS 15.0, *) {
          result(self.current()?.isRecording ?? false)
        } else {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Relay a live-select confirm/cancel from an overlay engine to the control
  /// engine's record controller (it owns settings + output naming).
  func notifySelection(_ args: [String: Any]) {
    channel.invokeMethod("onRecordSelection", arguments: args)
  }

  /// Native entries for the menu-bar Stop/Abort/Pause items.
  func stopActive() {
    if #available(macOS 15.0, *) { Task { await current()?.stop() } }
  }

  func abortActive() {
    if #available(macOS 15.0, *) { Task { await current()?.abort() } }
  }

  func pauseActive() {
    if #available(macOS 15.0, *) { current()?.pause() }
  }

  func resumeActive() {
    if #available(macOS 15.0, *) { current()?.resume() }
  }

  @available(macOS 15.0, *)
  private func current() -> RecordingController? {
    if let c = controller as? RecordingController { return c }
    let c = RecordingController(events: { [weak self] method, args in
      self?.channel.invokeMethod(method, arguments: args)
    })
    c.onStateChange = { [weak self] active, graceful in
      self?.onRecordingStateChange?(active, graceful)
    }
    c.onPauseChange = { [weak self] paused in
      self?.onRecordingPauseChange?(paused)
    }
    controller = c
    return c
  }

  @available(macOS 15.0, *)
  private func start(args: [String: Any]) {
    guard let controller = current(), !controller.isRecording else {
      channel.invokeMethod(
        "onRecordFailed", arguments: ["message": "already recording"])
      return
    }
    let mode = (args["mode"] as? String) ?? "display"
    let fps = (args["fps"] as? Int) ?? 30
    let hevc = (args["hevc"] as? Bool) ?? false
    let gif = (args["gif"] as? Bool) ?? false
    let showsCursor = (args["showsCursor"] as? Bool) ?? true
    let showScrim = (args["showScrim"] as? Bool) ?? true
    let systemAudio = (args["systemAudio"] as? Bool) ?? false
    let microphone = (args["microphone"] as? Bool) ?? false
    let maxDuration = (args["maxDuration"] as? Int) ?? 0
    let countdown = (args["countdown"] as? Int) ?? 0
    let outputPath = (args["outputPath"] as? String) ?? ""
    guard !outputPath.isEmpty else {
      channel.invokeMethod(
        "onRecordFailed", arguments: ["message": "missing outputPath"])
      return
    }

    func specRect() -> CGRect? {
      guard let x = args["x"] as? Double, let y = args["y"] as? Double,
            let w = args["w"] as? Double, let h = args["h"] as? Double
      else { return nil }
      return CGRect(x: x, y: y, width: w, height: h)
    }
    let displayID = (args["displayId"] as? NSNumber).map {
      CGDirectDisplayID($0.uint32Value)
    }
    let windowID = (args["windowId"] as? NSNumber).map {
      CGWindowID($0.uint32Value)
    }

    func begin(rect: CGRect?, display: CGDirectDisplayID?) {
      let spec = RecordingController.Spec(
        mode: mode, displayID: display, rect: rect, windowID: windowID,
        fps: fps, hevc: hevc, gif: gif, showsCursor: showsCursor,
        showScrim: showScrim,
        systemAudio: systemAudio, microphone: microphone,
        maxDuration: maxDuration, countdown: countdown, outputPath: outputPath)
      Task { await controller.start(spec) }
    }

    // Region selection happens in the Flutter overlay's live-select session
    // (owner mandate: capture/recording share ONE selection UI); every mode
    // arrives here fully resolved.
    begin(rect: specRect(), display: displayID)
  }
}
