import Cocoa
import FlutterMacOS

/// Registered on the control window's engine. Bridges the Dart hotkey to the
/// native capture trigger. Capture logic lives in CaptureController; window/
/// engine lifecycle in OverlayManager.
final class CaptureChannel {
  private let channel: FlutterMethodChannel
  private let capture: CaptureController
  private let manager: () -> OverlayManager?

  /// Menu-bar processing-pulse driver from the Dart capture/flow pipeline:
  /// (active) — true at capture commit (shutter moment), false when the output
  /// is delivered. Independent of the shutter-sound setting (purely visual).
  var onCaptureProcessingChange: ((Bool) -> Void)?

  init(
    messenger: FlutterBinaryMessenger,
    capture: CaptureController,
    manager: @escaping () -> OverlayManager?
  ) {
    self.capture = capture
    self.manager = manager
    channel = FlutterMethodChannel(name: "glimpr/capture", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "beginCapture":
        let a = call.arguments as? [String: Any]
        self?.capture.triggerCapture(
          pinOnly: (a?["pinOnly"] as? Bool) ?? false,
          liveSelect: (a?["liveSelect"] as? Bool) ?? false)
        result(nil)
      case "dismissOverlay": self?.manager()?.dismiss(); result(nil)
      // Menu-bar processing pulse: capture committed (true) / delivered (false).
      case "setProcessing":
        let active = (call.arguments as? [String: Any])?["active"] as? Bool
          ?? false
        DispatchQueue.main.async { self?.onCaptureProcessingChange?(active) }
        result(nil)
      // Record hotkey while a record-select is in flight: relay to every overlay
      // engine to resurface a suspended picker / cancel a foreground one.
      case "recordSelectHotkey":
        self?.manager()?.relayRecordSelectHotkey()
        result(nil)
      // After-capture flow: open the just-exported file in the image editor.
      case "openInEditor":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          DispatchQueue.main.async {
            MainFlutterWindow.shared?.openImageFromExternal(path)
          }
        }
        result(nil)
      // After-capture flow: macOS share sheet for the exported file.
      case "shareSheet":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          DispatchQueue.main.async {
            MainFlutterWindow.shared?.showShareSheet(path: path)
          }
        }
        result(nil)
      // After-capture flow: float the exported file as an always-on-top pin.
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
      // A capture flow wrote the shared recent-images store: forward a refresh
      // to the editor engine (it owns the landing gallery + Open Recent menu).
      case "recentChanged":
        DispatchQueue.main.async {
          MainFlutterWindow.shared?.notifyRecentChanged()
        }
        result(nil)
      case "perfMark":
        if let label = (call.arguments as? [String: Any])?["label"] as? String {
          PerfLog.mark(label)
        }
        result(nil)
      // Precise element snap (Advanced): does the app hold AX permission?
      case "accessibilityTrusted":
        result(ElementSnap.trusted())
      // Prompt for AX permission (system dialog / System Settings deep link).
      case "requestAccessibility":
        ElementSnap.requestTrust()
        result(nil)
      case "captureRegion":
        // Main actor like triggerCapture: the capture reaches NSScreen and the
        // channel reply must land on the platform (main) thread.
        let a = call.arguments as? [String: Any]
        let displayId = (a?["displayId"] as? NSNumber)?.uint32Value
        let rect: CGRect?
        if let x = a?["x"] as? Double, let y = a?["y"] as? Double,
           let w = a?["w"] as? Double, let h = a?["h"] as? Double {
          rect = CGRect(x: x, y: y, width: w, height: h)
        } else {
          rect = nil
        }
        let cursor = (a?["showsCursor"] as? Bool) ?? false
        let jpeg = (a?["jpeg"] as? Bool) ?? false
        let quality = (a?["quality"] as? Int) ?? 90
        // Opt-in decoration: decorate the captured CGImage natively before
        // encoding, so the direct path never round-trips pixels through Dart.
        let deco = (a?["decoration"] as? [String: Any]).flatMap(Decoration.spec)
        let alsoPlain = (a?["alsoPlain"] as? Bool) ?? false
        let hdr = (a?["hdr"] as? Bool) ?? false
        Task { @MainActor in
          do {
            let res = try await self?.capture.captureRegion(
              displayID: displayId.map { CGDirectDisplayID($0) }, rect: rect,
              showsCursor: cursor, jpeg: jpeg, jpegQuality: quality,
              decoration: deco, alsoPlain: alsoPlain, hdr: hdr)
            result(res) // nil -> Dart picks the fallback (display gone)
          } catch {
            result(FlutterError(
              code: "capture_failed", message: "\(error)", details: nil))
          }
        }
      case "focusedWindow":
        result(ScreenCapturer.focusedWindow())
      case "captureWindowImage":
        let a = call.arguments as? [String: Any]
        let wid = (a?["windowId"] as? NSNumber)?.uint32Value ?? 0
        let cursor = (a?["showsCursor"] as? Bool) ?? false
        Task { @MainActor in
          do {
            let img = try await self?.capture.captureWindowImage(
              windowID: CGWindowID(wid), showsCursor: cursor)
            result(img) // nil -> Dart treats as "no image" and falls back
          } catch {
            result(FlutterError(
              code: "capture_failed", message: "\(error)", details: nil))
          }
        }
      case "captureWindowDelivered":
        let a = call.arguments as? [String: Any]
        let wid = (a?["windowId"] as? NSNumber)?.uint32Value ?? 0
        let cursor = (a?["showsCursor"] as? Bool) ?? false
        let jpeg = (a?["jpeg"] as? Bool) ?? false
        let quality = (a?["quality"] as? Int) ?? 90
        let deco = (a?["decoration"] as? [String: Any]).flatMap(Decoration.spec)
        let alsoPlain = (a?["alsoPlain"] as? Bool) ?? false
        let hdr = (a?["hdr"] as? Bool) ?? false
        Task { @MainActor in
          do {
            let img = try await self?.capture.captureWindowDelivered(
              windowID: CGWindowID(wid), showsCursor: cursor, jpeg: jpeg,
              jpegQuality: quality, decoration: deco, alsoPlain: alsoPlain,
              hdr: hdr)
            result(img) // nil -> Dart falls back to a rectangular crop
          } catch {
            result(FlutterError(
              code: "capture_failed", message: "\(error)", details: nil))
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// CoreGraphics image decoration — margin + rounded-corners (or alpha-shape)
/// + drop shadow + optional background fill. Shared by two callers: the direct
/// capture path decorates the captured CGImage in place before encoding (no
/// Dart pixel round-trip), and the editor's `glimpr/encode` `decorate` method
/// decorates a Dart-composited RGBA frame (the overlay annotated path). Mirrors
/// the Dart `applyDecoration` appearance; shadows are NOT required to be
/// pixel-identical across platforms (owner ruling), so CG's shadow model is
/// used directly.
enum Decoration {
  /// Appearance parameters. Lengths are pre-scale (logical) and multiplied by
  /// `scale` in [render]; pass already-native-px values with `scale == 1`.
  struct Spec {
    let margin: CGFloat
    let cornerRadius: CGFloat
    let shadowBlur: CGFloat
    let shadowDx: CGFloat
    let shadowDy: CGFloat  // Flutter sense: +y points DOWN
    let shadowColor: CGColor
    let fill: CGColor?  // nil -> transparent margins (PNG); set -> JPEG fill
    let shapeFromAlpha: Bool  // window: cast the shadow from the content alpha
  }

  /// Parse the channel `decoration` dict. Lengths are doubles; colours are
  /// ARGB ints (Flutter `Color.toARGB32()`). `fill` absent -> transparent.
  static func spec(from a: [String: Any]) -> Spec? {
    guard let margin = (a["margin"] as? NSNumber)?.doubleValue,
          let radius = (a["cornerRadius"] as? NSNumber)?.doubleValue,
          let blur = (a["shadowBlur"] as? NSNumber)?.doubleValue,
          let dx = (a["shadowDx"] as? NSNumber)?.doubleValue,
          let dy = (a["shadowDy"] as? NSNumber)?.doubleValue,
          let shadow = (a["shadowColor"] as? NSNumber)?.uint32Value
    else { return nil }
    let fill = (a["fill"] as? NSNumber)?.uint32Value
    return Spec(
      margin: CGFloat(margin), cornerRadius: CGFloat(radius),
      shadowBlur: CGFloat(blur), shadowDx: CGFloat(dx), shadowDy: CGFloat(dy),
      shadowColor: cgColor(argb: shadow),
      fill: fill.map { cgColor(argb: $0) },
      shapeFromAlpha: (a["shapeFromAlpha"] as? Bool) ?? false)
  }

  static func cgColor(argb: UInt32) -> CGColor {
    CGColor(
      srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255)
  }

  /// Render `content` decorated into a new, larger CGImage, scaling the spec's
  /// lengths by `scale`. Returns nil only if a bitmap context can't be made.
  static func render(_ content: CGImage, spec: Spec, scale: CGFloat) -> CGImage? {
    let radius = spec.cornerRadius * scale
    let blur = spec.shadowBlur * scale
    let dx = spec.shadowDx * scale
    let dy = spec.shadowDy * scale
    // effectiveMargin: never smaller than the shadow reach (mirrors Dart).
    let m = max(spec.margin * scale, blur + max(abs(dx), abs(dy)))
    let cw = CGFloat(content.width), ch = CGFloat(content.height)
    let outW = Int((cw + 2 * m).rounded()), outH = Int((ch + 2 * m).rounded())
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // CoreGraphics is bottom-left; anchor the content so the TOP margin is m
    // (matches Dart's top-left Offset(m, m)). Flutter's +y-down shadow offset
    // becomes -dy in this space.
    let contentRect = CGRect(
      x: m, y: CGFloat(outH) - m - ch, width: cw, height: ch)
    if let fill = spec.fill {
      ctx.setFillColor(fill)
      ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH)))
    }
    let shadowOffset = CGSize(width: dx, height: -dy)
    if spec.shapeFromAlpha {
      // The content carries its real silhouette; cast the shadow from its alpha
      // and draw the content on top in one pass (no rounded-rect clip).
      ctx.saveGState()
      ctx.setShadow(offset: shadowOffset, blur: blur, color: spec.shadowColor)
      ctx.draw(content, in: contentRect)
      ctx.restoreGState()
    } else {
      let path = CGPath(
        roundedRect: contentRect, cornerWidth: radius, cornerHeight: radius,
        transform: nil)
      // Cast the rounded-rect shadow from an opaque fill (then covered by the
      // opaque capture, so the fill colour never shows).
      ctx.saveGState()
      ctx.setShadow(offset: shadowOffset, blur: blur, color: spec.shadowColor)
      ctx.addPath(path)
      ctx.setFillColor(CGColor(gray: 0, alpha: 1))
      ctx.fillPath()
      ctx.restoreGState()
      // Content, clipped to the rounded rect (also trims a snapped window's
      // corner-gap pixels).
      ctx.saveGState()
      ctx.addPath(path)
      ctx.clip()
      ctx.draw(content, in: contentRect)
      ctx.restoreGState()
    }
    return ctx.makeImage()
  }

  /// A CGImage wrapping tightly-packed RGBA8888 (premultiplied) — the dart:ui
  /// rawRgba layout, matching premultipliedLast.
  static func cgImage(rgba: Data, width: Int, height: Int) -> CGImage? {
    var pixels = rgba
    return pixels.withUnsafeMutableBytes { buf -> CGImage? in
      guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
              data: buf.baseAddress, width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      return ctx.makeImage()
    }
  }

  /// Encode a CGImage to PNG or JPEG (ImageIO via NSBitmapImageRep).
  static func encode(_ image: CGImage, jpeg: Bool, quality: Int) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    if jpeg {
      let q = max(0, min(100, quality))
      return rep.representation(
        using: .jpeg, properties: [.compressionFactor: Double(q) / 100.0])
    }
    return rep.representation(using: .png, properties: [:])
  }
}

/// Native encoder for the editor layer, registered on EVERY engine's messenger
/// (control / overlay / image editor) so `composite.dart` can call it
/// host-agnostically. `jpeg`: raw RGBA8888 in, JPEG bytes out (the pure-Dart
/// image-package encoder took seconds for a 5K frame). `decorate`: raw RGBA8888
/// + a decoration spec in, the decorated frame encoded (PNG/JPEG) out — used by
/// the overlay annotated path, where annotations must composite in Dart first.
enum EncodeChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "glimpr/encode", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "jpeg":
        guard let a = call.arguments as? [String: Any],
              let data = a["rgba"] as? FlutterStandardTypedData,
              let w = a["width"] as? Int, let h = a["height"] as? Int,
              w > 0, h > 0, data.data.count >= w * h * 4
        else { result(nil); return }
        let quality = max(0, min(100, (a["quality"] as? Int) ?? 90))
        // CPU-bound encode off the platform thread; the reply hops back.
        DispatchQueue.global(qos: .userInitiated).async {
          let bytes = Self.encodeJpeg(
            rgba: data.data, width: w, height: h, quality: quality)
          DispatchQueue.main.async {
            result(bytes.map { FlutterStandardTypedData(bytes: $0) })
          }
        }
      case "png":
        // Raw RGBA8888 in, PNG bytes out (ImageIO). dart:ui's own PNG encode
        // measured ~700ms for a 16.7MP editor export; this is the same swap
        // the JPEG path already made. Alpha is preserved (window-shape masks).
        guard let a = call.arguments as? [String: Any],
              let data = a["rgba"] as? FlutterStandardTypedData,
              let w = a["width"] as? Int, let h = a["height"] as? Int,
              w > 0, h > 0, data.data.count >= w * h * 4
        else { result(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
          let out = Decoration.cgImage(rgba: data.data, width: w, height: h)
            .flatMap { Decoration.encode($0, jpeg: false, quality: 100) }
          DispatchQueue.main.async {
            result(out.map { FlutterStandardTypedData(bytes: $0) })
          }
        }
      case "decorate":
        guard let a = call.arguments as? [String: Any],
              let data = a["rgba"] as? FlutterStandardTypedData,
              let w = a["width"] as? Int, let h = a["height"] as? Int,
              w > 0, h > 0, data.data.count >= w * h * 4,
              let deco = a["decoration"] as? [String: Any],
              let spec = Decoration.spec(from: deco)
        else { result(nil); return }
        let scale = CGFloat((a["scale"] as? NSNumber)?.doubleValue ?? 1.0)
        let jpeg = (a["jpeg"] as? Bool) ?? false
        let quality = max(0, min(100, (a["quality"] as? Int) ?? 90))
        DispatchQueue.global(qos: .userInitiated).async {
          var out: Data?
          if let cg = Decoration.cgImage(rgba: data.data, width: w, height: h),
             let decorated = Decoration.render(cg, spec: spec, scale: scale) {
            out = Decoration.encode(decorated, jpeg: jpeg, quality: quality)
          }
          DispatchQueue.main.async {
            result(out.map { FlutterStandardTypedData(bytes: $0) })
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// dart:ui rawRgba layout = R,G,B,A bytes, premultiplied — matches a
  /// premultipliedLast big-endian CGContext. Content is effectively opaque
  /// (captures; JPEG fills), so premultiplication is a no-op in practice.
  private static func encodeJpeg(
    rgba: Data, width: Int, height: Int, quality: Int
  ) -> Data? {
    var pixels = rgba
    let rowBytes = width * 4
    let cg: CGImage? = pixels.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(
        data: buf.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: rowBytes,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      return ctx.makeImage()
    }
    guard let image = cg else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(
      using: .jpeg,
      properties: [.compressionFactor: Double(quality) / 100.0])
  }
}

/// Self-owned image clipboard, registered on EVERY engine's messenger (control
/// / overlay / image editor) so the editor layer can read/write the system
/// clipboard host-agnostically — replacing the `pasteboard` package. WRITE puts
/// the already-encoded image on the pasteboard: PNG bytes go straight to the
/// `.png` type (no NSImage/TIFF detour); other encodings (JPEG) are decoded
/// once to PNG. READ returns the clipboard image as PNG bytes.
enum ClipboardChannel {
  // PNG file signature.
  private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "glimpr/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "writeImage":
        guard let a = call.arguments as? [String: Any],
              let data = (a["bytes"] as? FlutterStandardTypedData)?.data
        else {
          result(FlutterError(code: "bad_args", message: "no bytes", details: nil))
          return
        }
        if data.starts(with: pngMagic) {
          // Already PNG — write the bytes directly on the platform thread.
          result(Self.put(png: data)
            ? nil
            : FlutterError(code: "clipboard_write", message: "write failed", details: nil))
        } else {
          // JPEG etc. — decode to PNG off the platform thread, then write.
          DispatchQueue.global(qos: .userInitiated).async {
            let png = Self.toPNG(data)
            DispatchQueue.main.async {
              guard let png else {
                result(FlutterError(
                  code: "clipboard_write", message: "not an image", details: nil))
                return
              }
              result(Self.put(png: png)
                ? nil
                : FlutterError(code: "clipboard_write", message: "write failed", details: nil))
            }
          }
        }
      case "readImage":
        // NSPasteboard reads on the platform (main) thread.
        result(Self.readImage().map { FlutterStandardTypedData(bytes: $0) })
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Put PNG bytes on the general pasteboard under the `.png` type.
  private static func put(png: Data) -> Bool {
    let item = NSPasteboardItem()
    item.setData(png, forType: .png)
    let pb = NSPasteboard.general
    pb.clearContents()
    return pb.writeObjects([item])
  }

  /// Decode any image-encoded [data] (JPEG/TIFF/…) once to PNG bytes.
  private static func toPNG(_ data: Data) -> Data? {
    guard let img = NSImage(data: data), let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }

  /// The clipboard image as PNG bytes: the `.png` type directly when present,
  /// else any image (TIFF etc.) converted to PNG. nil when no image is present.
  private static func readImage() -> Data? {
    let pb = NSPasteboard.general
    if let png = pb.data(forType: .png) { return png }
    guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}

/// Hosts the "glimpr/sound" method channel: play a short feedback cue (shutter /
/// completion) whose wav bytes arrive raw from Dart. Plays via NSSound, the
/// native AppKit player — this replaces the `audioplayers` package (whose
/// Windows backend crashed during recording; macOS moves to the native path too
/// for one uniform seam). Registered on every engine, like ClipboardChannel.
enum SoundChannel {
  // NSSound is released (and playback cut) once nothing references it, so live
  // cues are retained until they finish; separate sounds overlap rather than
  // cut each other off (the prior two-player behaviour).
  private static let keeper = SoundKeeper()

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "glimpr/sound", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "play":
        guard let a = call.arguments as? [String: Any],
              let data = (a["bytes"] as? FlutterStandardTypedData)?.data,
              let sound = NSSound(data: data)
        else {
          result(FlutterError(
            code: "sound_play", message: "invalid cue bytes", details: nil))
          return
        }
        keeper.play(sound)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Retains in-flight NSSound cues until they finish playing, then drops them.
private final class SoundKeeper: NSObject, NSSoundDelegate {
  private var live: [NSSound] = []

  func play(_ sound: NSSound) {
    sound.delegate = self
    live.append(sound)
    if !sound.play() { live.removeAll { $0 === sound } }
  }

  func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
    live.removeAll { $0 === sound }
  }
}
