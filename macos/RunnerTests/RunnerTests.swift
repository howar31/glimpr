import Cocoa
import ScreenCaptureKit
import XCTest

@testable import Glimpr

// Host-based pure-logic tests. The full app (a menu-bar agent) loads as the
// test host, which is fine: nothing here triggers capture, recording, or AX
// flows — only pure helpers and never-shown AppKit objects are exercised.
//
// All test classes live in this ONE file on purpose: new Swift files need four
// pbxproj entries to compile, so the first wave avoids pbxproj surgery.

// MARK: - Decoration.spec / cgColor (CaptureChannel.swift)

final class DecorationSpecTests: XCTestCase {
  private func fullArgs() -> [String: Any] {
    [
      "margin": 12.5, "cornerRadius": 3.0, "shadowBlur": 4.5,
      "shadowDx": 1.0, "shadowDy": -2.0,
      "shadowColor": 0x80112233, "fill": 0xFF445566,
      "shapeFromAlpha": true,
    ]
  }

  func testSpecParsesAllFields() {
    guard let s = Decoration.spec(from: fullArgs()) else {
      return XCTFail("a complete dict must parse")
    }
    XCTAssertEqual(s.margin, 12.5)
    XCTAssertEqual(s.cornerRadius, 3.0)
    XCTAssertEqual(s.shadowBlur, 4.5)
    XCTAssertEqual(s.shadowDx, 1.0)
    XCTAssertEqual(s.shadowDy, -2.0)
    XCTAssertTrue(s.shapeFromAlpha)
    assertARGB(s.shadowColor, a: 0x80, r: 0x11, g: 0x22, b: 0x33)
    guard let fill = s.fill else { return XCTFail("fill key present -> fill set") }
    assertARGB(fill, a: 0xFF, r: 0x44, g: 0x55, b: 0x66)
  }

  func testSpecOptionalDefaults() {
    var a = fullArgs()
    a.removeValue(forKey: "fill")
    a.removeValue(forKey: "shapeFromAlpha")
    let s = Decoration.spec(from: a)
    XCTAssertNil(s?.fill, "fill absent -> transparent margins")
    XCTAssertEqual(s?.shapeFromAlpha, false)
  }

  func testSpecRejectsMissingRequiredKeys() {
    let required = [
      "margin", "cornerRadius", "shadowBlur", "shadowDx", "shadowDy",
      "shadowColor",
    ]
    for key in required {
      var a = fullArgs()
      a.removeValue(forKey: key)
      XCTAssertNil(Decoration.spec(from: a), "missing \(key) must fail")
    }
  }

  func testSpecAcceptsIntegerNumbers() {
    // Flutter sends NSNumbers; whole values can arrive integer-typed.
    let a: [String: Any] = [
      "margin": 12, "cornerRadius": 3, "shadowBlur": 4,
      "shadowDx": 1, "shadowDy": -2, "shadowColor": 0x40000000,
    ]
    let s = Decoration.spec(from: a)
    XCTAssertEqual(s?.margin, 12)
    XCTAssertEqual(s?.shadowDy, -2)
  }

  func testCgColorBitLanes() {
    assertARGB(
      Decoration.cgColor(argb: 0x80FF8040), a: 0x80, r: 0xFF, g: 0x80, b: 0x40)
    assertARGB(Decoration.cgColor(argb: 0x00000000), a: 0, r: 0, g: 0, b: 0)
    assertARGB(
      Decoration.cgColor(argb: 0xFFFFFFFF), a: 0xFF, r: 0xFF, g: 0xFF, b: 0xFF)
  }

  /// Assert an sRGB CGColor's lanes match the given 8-bit ARGB channels.
  private func assertARGB(
    _ c: CGColor, a: UInt32, r: UInt32, g: UInt32, b: UInt32,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let comp = c.components, comp.count >= 4 else {
      return XCTFail("color has no RGBA components", file: file, line: line)
    }
    XCTAssertEqual(Double(comp[0]), Double(r) / 255, accuracy: 1e-6,
                   "red", file: file, line: line)
    XCTAssertEqual(Double(comp[1]), Double(g) / 255, accuracy: 1e-6,
                   "green", file: file, line: line)
    XCTAssertEqual(Double(comp[2]), Double(b) / 255, accuracy: 1e-6,
                   "blue", file: file, line: line)
    XCTAssertEqual(Double(c.alpha), Double(a) / 255, accuracy: 1e-6,
                   "alpha", file: file, line: line)
  }
}

// MARK: - Decoration.render / encode (CaptureChannel.swift)

final class DecorationRenderTests: XCTestCase {
  /// A solid opaque white CGImage (also exercises Decoration.cgImage).
  private func solidContent(width: Int, height: Int) -> CGImage? {
    var rgba = Data(count: width * height * 4)
    rgba.withUnsafeMutableBytes { buf in
      memset(buf.baseAddress, 0xFF, buf.count)
    }
    return Decoration.cgImage(rgba: rgba, width: width, height: height)
  }

  private func spec(
    margin: CGFloat, blur: CGFloat, dx: CGFloat, dy: CGFloat,
    radius: CGFloat = 2, fill: CGColor? = nil, shapeFromAlpha: Bool = false
  ) -> Decoration.Spec {
    Decoration.Spec(
      margin: margin, cornerRadius: radius, shadowBlur: blur,
      shadowDx: dx, shadowDy: dy,
      shadowColor: Decoration.cgColor(argb: 0x66000000),
      fill: fill, shapeFromAlpha: shapeFromAlpha)
  }

  func testRenderMarginDominatedGeometry() throws {
    let content = try XCTUnwrap(solidContent(width: 8, height: 6))
    // effectiveMargin = max(10*2, 4*2 + max(|2|, |3|)*2) = max(20, 14) = 20.
    let out = Decoration.render(
      content, spec: spec(margin: 10, blur: 4, dx: 2, dy: 3), scale: 2)
    XCTAssertNotNil(out)
    XCTAssertEqual(out?.width, 8 + 2 * 20)
    XCTAssertEqual(out?.height, 6 + 2 * 20)
  }

  func testRenderShadowReachExpandsMargin() throws {
    let content = try XCTUnwrap(solidContent(width: 8, height: 6))
    // effectiveMargin = max(1, 10 + max(|6|, |-8|)) = 18 (dy sign ignored).
    let out = Decoration.render(
      content, spec: spec(margin: 1, blur: 10, dx: 6, dy: -8), scale: 1)
    XCTAssertNotNil(out)
    XCTAssertEqual(out?.width, 8 + 2 * 18)
    XCTAssertEqual(out?.height, 6 + 2 * 18)
  }

  func testRenderFillAndAlphaShapeSameGeometry() throws {
    let content = try XCTUnwrap(solidContent(width: 8, height: 6))
    // The fill and shapeFromAlpha branches must not change the output size.
    let s = spec(margin: 5, blur: 0, dx: 0, dy: 0,
                 fill: Decoration.cgColor(argb: 0xFFFFFFFF),
                 shapeFromAlpha: true)
    let out = Decoration.render(content, spec: s, scale: 1)
    XCTAssertNotNil(out)
    XCTAssertEqual(out?.width, 8 + 2 * 5)
    XCTAssertEqual(out?.height, 6 + 2 * 5)
  }

  func testEncodePngMagic() throws {
    let img = try XCTUnwrap(solidContent(width: 4, height: 4))
    let data = try XCTUnwrap(Decoration.encode(img, jpeg: false, quality: 90))
    XCTAssertEqual([UInt8](data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
  }

  func testEncodeJpegMagicAndQualityClamp() throws {
    let img = try XCTUnwrap(solidContent(width: 4, height: 4))
    // Out-of-range qualities clamp to [0, 100] instead of failing.
    for q in [-10, 0, 55, 100, 150] {
      guard let data = Decoration.encode(img, jpeg: true, quality: q) else {
        return XCTFail("quality \(q) must clamp, not fail")
      }
      XCTAssertEqual([UInt8](data.prefix(3)), [0xFF, 0xD8, 0xFF],
                     "JPEG magic for quality \(q)")
    }
  }
}

// MARK: - ScreenCapturer.windowBounds (OverlayKit.swift)

final class ScreenCapturerWindowBoundsTests: XCTestCase {
  private let boundsKey = kCGWindowBounds as String

  func testValidBoundsDict() {
    let w: [String: Any] = [
      boundsKey: ["X": 12.5, "Y": -3.0, "Width": 640.0, "Height": 480.0]
    ]
    XCTAssertEqual(
      ScreenCapturer.windowBounds(w),
      CGRect(x: 12.5, y: -3, width: 640, height: 480))
  }

  func testIntegerNumbersAccepted() {
    let w: [String: Any] = [
      boundsKey: ["X": 1, "Y": 2, "Width": 3, "Height": 4]
    ]
    XCTAssertEqual(
      ScreenCapturer.windowBounds(w), CGRect(x: 1, y: 2, width: 3, height: 4))
  }

  func testMissingOrGarbageKeysReturnNil() {
    XCTAssertNil(ScreenCapturer.windowBounds([:]), "no bounds key")
    XCTAssertNil(
      ScreenCapturer.windowBounds(
        [boundsKey: ["X": 1.0, "Y": 2.0, "Width": 3.0]]),
      "missing Height")
    XCTAssertNil(
      ScreenCapturer.windowBounds(
        [boundsKey: ["X": "left", "Y": 2.0, "Width": 3.0, "Height": 4.0]]),
      "non-numeric X")
    XCTAssertNil(
      ScreenCapturer.windowBounds([boundsKey: "not a dict"]),
      "bounds value is not a dict")
  }
}

// MARK: - ScreenCapturer.fillsBuffer (OverlayKit.swift)

final class ScreenCapturerFillsBufferTests: XCTestCase {
  /// A packed RGBA bitmap with every byte set to [byte] (0xFF = opaque white).
  private func rep(width: Int, height: Int, byte: UInt8) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let data = rep.bitmapData
    else { return nil }
    memset(data, Int32(byte), rep.bytesPerRow * height)
    return rep
  }

  private func clearPixel(_ rep: NSBitmapImageRep, x: Int, y: Int) {
    guard let data = rep.bitmapData else { return }
    let p = data + y * rep.bytesPerRow + x * 4
    for i in 0..<4 { p[i] = 0 } // fully transparent RGBA pixel
  }

  func testFullyOpaqueFills() throws {
    let r = try XCTUnwrap(rep(width: 20, height: 20, byte: 0xFF))
    XCTAssertTrue(ScreenCapturer.fillsBuffer(r))
  }

  func testTransparentEdgeMidpointFails() throws {
    // The four probes for a 20x20 rep (inset 2): top / bottom / left / right
    // edge midpoints.
    let probes = [(10, 2), (10, 17), (2, 10), (17, 10)]
    for (x, y) in probes {
      let r = try XCTUnwrap(rep(width: 20, height: 20, byte: 0xFF))
      clearPixel(r, x: x, y: y)
      XCTAssertFalse(
        ScreenCapturer.fillsBuffer(r), "transparent midpoint at (\(x), \(y))")
    }
  }

  func testTinyBufferIsTrusted() throws {
    // <= 6 px on a side: too small to judge, trusted even when transparent.
    let r = try XCTUnwrap(rep(width: 5, height: 5, byte: 0x00))
    XCTAssertTrue(ScreenCapturer.fillsBuffer(r))
  }
}

// MARK: - Snappable window levels (OverlayKit.swift + ElementSnap.swift)

final class SnapLevelsTests: XCTestCase {
  func testSnappableWindowLevelsValue() {
    // Normal app windows (0), floating panels (3), modal alerts (8).
    XCTAssertEqual(ScreenCapturer.snappableWindowLevels, Set([0, 3, 8]))
  }

  func testElementSnapSharesTheSameLevels() {
    // Both snap paths must admit the same windows — this pins them together.
    XCTAssertEqual(ElementSnap.appLevels, ScreenCapturer.snappableWindowLevels)
  }
}

// MARK: - RecordingChrome math (RecordingKit.swift)

@MainActor
final class RecordingChromeMathTests: XCTestCase {
  func testMmss() {
    let chrome = RecordingChrome() // plain init: no windows are built
    XCTAssertEqual(chrome.mmss(0), "00:00")
    XCTAssertEqual(chrome.mmss(59), "00:59")
    XCTAssertEqual(chrome.mmss(60), "01:00")
    XCTAssertEqual(chrome.mmss(605), "10:05")
    XCTAssertEqual(chrome.mmss(3599), "59:59")
    XCTAssertEqual(chrome.mmss(3600), "60:00", "whole minutes, no hour wrap")
  }

  private func someScreen() throws -> NSScreen {
    guard let s = NSScreen.main ?? NSScreen.screens.first else {
      throw XCTSkip("no screen attached to the test host")
    }
    return s
  }

  func testStripOriginBottomCenterBelowRegion() throws {
    let screen = try someScreen()
    let vf = screen.visibleFrame
    let region = NSRect(x: vf.midX - 100, y: vf.midY - 50, width: 200, height: 100)
    let size = NSSize(width: 300, height: 40)
    let o = RecordingChrome.stripOrigin(
      forRegion: region, on: screen, stripSize: size)
    XCTAssertEqual(o.x, region.midX - size.width / 2, accuracy: 0.001)
    XCTAssertEqual(o.y, region.minY - size.height - 8, accuracy: 0.001)
  }

  func testStripOriginNoRoomBelowTucksInside() throws {
    let screen = try someScreen()
    let vf = screen.visibleFrame
    // Region bottom hugs the visible frame: no room below.
    let region = NSRect(x: vf.midX - 100, y: vf.minY, width: 200, height: 100)
    let size = NSSize(width: 300, height: 40)
    let o = RecordingChrome.stripOrigin(
      forRegion: region, on: screen, stripSize: size)
    XCTAssertEqual(o.y, region.minY + 8, accuracy: 0.001,
                   "tucks INSIDE the region bottom — never flips to the top")
  }

  func testStripOriginClampsToVisibleFrame() throws {
    let screen = try someScreen()
    let vf = screen.visibleFrame
    // Region mostly off the left edge: x clamps to the visible-frame inset.
    let region = NSRect(x: vf.minX - 400, y: vf.midY, width: 200, height: 100)
    let size = NSSize(width: 300, height: 40)
    let o = RecordingChrome.stripOrigin(
      forRegion: region, on: screen, stripSize: size)
    XCTAssertEqual(o.x, vf.minX + 4, accuracy: 0.001)
  }
}

// MARK: - RecordingController pacing math (RecordingKit.swift)

@MainActor
final class RecordingPacingTests: XCTestCase {
  func testEven() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    XCTAssertEqual(RecordingController.even(8), 8)
    XCTAssertEqual(RecordingController.even(7), 6)
    XCTAssertEqual(RecordingController.even(2), 2)
    XCTAssertEqual(RecordingController.even(1), 2, "floors at 2")
    XCTAssertEqual(RecordingController.even(0), 2, "floors at 2")
  }

  func testCapLongSideDownscalesKeepingAspect() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    let cfg = SCStreamConfiguration()
    cfg.width = 3840
    cfg.height = 2160
    RecordingController.capLongSide(cfg, to: 1920)
    XCTAssertEqual(cfg.width, 1920)
    XCTAssertEqual(cfg.height, 1080)
  }

  func testCapLongSideRoundsToEven() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    let cfg = SCStreamConfiguration()
    cfg.width = 3839
    cfg.height = 2159
    RecordingController.capLongSide(cfg, to: 1000)
    XCTAssertEqual(cfg.width, 1000)
    XCTAssertEqual(cfg.height, 562) // 2159 * 1000/3839 = 562.4 -> 562 (even)
  }

  func testCapLongSideNoOpCases() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    let cfg = SCStreamConfiguration()
    cfg.width = 800
    cfg.height = 600
    RecordingController.capLongSide(cfg, to: 0) // 0 = no cap
    XCTAssertEqual(cfg.width, 800)
    XCTAssertEqual(cfg.height, 600)
    RecordingController.capLongSide(cfg, to: 800) // already within the cap
    XCTAssertEqual(cfg.width, 800)
    XCTAssertEqual(cfg.height, 600)
  }
}

// MARK: - RecordingChannel.parseSpec (RecordingKit.swift)

@MainActor
final class RecordingChannelParseSpecTests: XCTestCase {
  func testMissingOutputPathFails() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    XCTAssertNil(RecordingChannel.parseSpec(args: [:]))
    XCTAssertNil(RecordingChannel.parseSpec(args: ["outputPath": ""]))
  }

  func testDefaults() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    guard let s = RecordingChannel.parseSpec(args: ["outputPath": "/tmp/out.mp4"])
    else { return XCTFail("minimal args must parse") }
    XCTAssertEqual(s.mode, "display")
    XCTAssertNil(s.displayID)
    XCTAssertNil(s.rect)
    XCTAssertNil(s.windowID)
    XCTAssertEqual(s.fps, 30)
    XCTAssertFalse(s.hevc)
    XCTAssertFalse(s.hdr)
    XCTAssertFalse(s.gif)
    XCTAssertTrue(s.showsCursor)
    XCTAssertTrue(s.showScrim)
    XCTAssertFalse(s.systemAudio)
    XCTAssertFalse(s.microphone)
    XCTAssertFalse(s.mergeAudio)
    XCTAssertEqual(s.maxDuration, 0)
    XCTAssertEqual(s.countdown, 0)
    XCTAssertEqual(s.videoQuality, "high")
    XCTAssertEqual(s.maxLongSide, 0)
    XCTAssertEqual(s.gifFps, 15)
    XCTAssertEqual(s.outputPath, "/tmp/out.mp4")
  }

  func testFullArgsAndRect() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    let args: [String: Any] = [
      "mode": "region",
      "x": 10.0, "y": 20.0, "w": 300.0, "h": 200.0,
      "displayId": 69733382, "windowId": 42,
      "fps": 60, "hevc": true, "hdr": true, "gif": true,
      "showsCursor": false, "showScrim": false,
      "systemAudio": true, "microphone": true, "mergeAudio": true,
      "maxDuration": 90, "countdown": 3,
      "videoQuality": "low", "maxLongSide": 1280, "gifFps": 24,
      "outputPath": "/tmp/r.gif",
    ]
    guard let s = RecordingChannel.parseSpec(args: args) else {
      return XCTFail("full args must parse")
    }
    XCTAssertEqual(s.mode, "region")
    XCTAssertEqual(s.rect, CGRect(x: 10, y: 20, width: 300, height: 200))
    XCTAssertEqual(s.displayID, 69733382)
    XCTAssertEqual(s.windowID, 42)
    XCTAssertEqual(s.fps, 60)
    XCTAssertTrue(s.hevc)
    XCTAssertTrue(s.hdr)
    XCTAssertTrue(s.gif)
    XCTAssertFalse(s.showsCursor)
    XCTAssertFalse(s.showScrim)
    XCTAssertTrue(s.systemAudio)
    XCTAssertTrue(s.microphone)
    XCTAssertTrue(s.mergeAudio)
    XCTAssertEqual(s.maxDuration, 90)
    XCTAssertEqual(s.countdown, 3)
    XCTAssertEqual(s.videoQuality, "low")
    XCTAssertEqual(s.maxLongSide, 1280)
    XCTAssertEqual(s.gifFps, 24)
    XCTAssertEqual(s.outputPath, "/tmp/r.gif")
  }

  func testPartialRectIsDropped() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    let args: [String: Any] = [
      "outputPath": "/tmp/x.mp4", "mode": "lastRegion",
      "x": 1.0, "y": 2.0, "w": 3.0, // no "h" -> the whole rect is dropped
    ]
    let s = RecordingChannel.parseSpec(args: args)
    XCTAssertEqual(s?.mode, "lastRegion")
    XCTAssertNil(s?.rect)
  }
}

// MARK: - AudioMixer math (RecordingKit.swift)

final class AudioMixerMathTests: XCTestCase {
  private func accumulate(
    _ acc: inout [Float], at offset: Int, _ samples: [Float]
  ) throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    samples.withUnsafeBufferPointer { buf in
      AudioMixer.accumulate(
        &acc, at: offset, from: buf.baseAddress!, frames: samples.count)
    }
  }

  func testAccumulateGrowsAndSums() throws {
    var acc: [Float] = []
    try accumulate(&acc, at: 0, [0.5, 0.25])
    XCTAssertEqual(acc, [0.5, 0.25])
    try accumulate(&acc, at: 1, [1, 1, 1]) // overlap + growth
    XCTAssertEqual(acc, [0.5, 1.25, 1, 1])
  }

  func testAccumulateOffsetPadsWithSilence() throws {
    var acc: [Float] = [1]
    try accumulate(&acc, at: 3, [0.5])
    XCTAssertEqual(acc, [1, 0, 0, 0.5])
  }

  func testAccumulateNegativeOffsetPadsButDrops() throws {
    var acc: [Float] = [1]
    // startFrame two before base, four frames: ends 2 past the current end,
    // so the accumulator grows by one zero — but the samples are dropped.
    try accumulate(&acc, at: -2, [0.5, 0.5, 0.5, 0.5])
    XCTAssertEqual(acc, [1, 0])
  }

  func testAccumulateDoesNotClamp() throws {
    var acc: [Float] = [0.9]
    try accumulate(&acc, at: 0, [0.9])
    XCTAssertEqual(acc, [1.8], "the clamp happens at flush, not accumulate")
  }

  func testFlushWatermark() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    XCTAssertEqual(AudioMixer.flushWatermark(sys: 100, mic: 80, lag: 50), 80)
    XCTAssertEqual(AudioMixer.flushWatermark(sys: 80, mic: 100, lag: 50), 80)
    XCTAssertEqual(AudioMixer.flushWatermark(sys: 64, mic: 64, lag: 50), 64)
    XCTAssertEqual(
      AudioMixer.flushWatermark(sys: 1000, mic: 100, lag: 50), 950,
      "a silent source is treated as at most lag behind the live one")
  }

  func testClamp() throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("recording is macOS 15+") }
    XCTAssertEqual(AudioMixer.clamp(0.5), 0.5)
    XCTAssertEqual(AudioMixer.clamp(1.7), 1)
    XCTAssertEqual(AudioMixer.clamp(-3), -1)
    XCTAssertEqual(AudioMixer.clamp(-1), -1)
    XCTAssertEqual(AudioMixer.clamp(1), 1)
  }
}

// MARK: - L localization (MainFlutterWindow.swift)

final class LocalizationTests: XCTestCase {
  // NOTE: L.zh is a `static let` resolved ONCE per process (by design — the
  // language applies on restart), so the preference variants are tested via
  // the extracted pure resolveZh, not by mutating UserDefaults.
  func testResolveZhExplicitPreference() {
    XCTAssertTrue(L.resolveZh(pref: "zh", systemLanguages: ["en-US"]))
    XCTAssertFalse(L.resolveZh(pref: "en", systemLanguages: ["zh-Hant-TW"]))
  }

  func testResolveZhSystemFallback() {
    XCTAssertTrue(L.resolveZh(pref: nil, systemLanguages: ["zh-Hant-TW", "en-US"]))
    XCTAssertTrue(L.resolveZh(pref: "system", systemLanguages: ["zh-TW"]))
    XCTAssertFalse(
      L.resolveZh(pref: nil, systemLanguages: ["en-US", "zh-Hant-TW"]),
      "only the FIRST system language decides")
    XCTAssertFalse(L.resolveZh(pref: "system", systemLanguages: []))
  }

  func testSFollowsResolvedLanguage() {
    // Whatever the host resolved at launch, s() must agree with L.zh.
    XCTAssertEqual(L.s("English", "中文"), L.zh ? "中文" : "English")
  }
}

// MARK: - PinPanel zoom (MainFlutterWindow.swift)

@MainActor
final class PinPanelTests: XCTestCase {
  /// A never-shown pin panel (init builds views/layers but does not order the
  /// window front). The private vapor margin is derived from the init
  /// geometry (frame = image frame inset by -margin) instead of hardcoding.
  private func makePanel(
    imageSize: NSSize = NSSize(width: 100, height: 80),
    at origin: NSPoint = NSPoint(x: 200, y: 200)
  ) -> (panel: PinPanel, imageFrame: NSRect, margin: CGFloat) {
    let imageFrame = NSRect(origin: origin, size: imageSize)
    let panel = PinPanel(image: NSImage(size: imageSize), frame: imageFrame)
    let margin = (panel.frame.width - imageSize.width) / 2
    return (panel, imageFrame, margin)
  }

  func testInitFrameSurroundsImageSymmetrically() {
    let (panel, imageFrame, margin) = makePanel()
    XCTAssertGreaterThan(margin, 0)
    XCTAssertEqual(panel.frame, imageFrame.insetBy(dx: -margin, dy: -margin))
  }

  func testSetZoomScalesImageAroundCenterKeepingMargin() {
    let (panel, imageFrame, margin) = makePanel()
    let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    panel.setZoom(2)
    XCTAssertEqual(panel.frame.width, imageFrame.width * 2 + margin * 2,
                   accuracy: 0.001)
    XCTAssertEqual(panel.frame.height, imageFrame.height * 2 + margin * 2,
                   accuracy: 0.001)
    XCTAssertEqual(panel.frame.midX, center.x, accuracy: 0.001)
    XCTAssertEqual(panel.frame.midY, center.y, accuracy: 0.001)
  }

  func testScrollWheelClampsZoom() throws {
    let (panel, imageFrame, margin) = makePanel()
    guard let ev = scrollEvent(wheel1: 100_000), ev.scrollingDeltaY != 0 else {
      throw XCTSkip("synthetic scroll events carry no scrolling delta here")
    }
    // A huge delta pushes the factor far outside [0.25, 3], so the zoom lands
    // exactly on a clamp rail: 3 for a positive delta, 0.25 for a negative
    // one (sign depends on the host's scroll-direction mapping).
    let factor = 1 + ev.scrollingDeltaY * 0.0025
    let expected = min(3, max(0.25, factor))
    panel.scrollWheel(with: ev)
    XCTAssertEqual(panel.frame.width, imageFrame.width * expected + margin * 2,
                   accuracy: 0.001)
    // Already at the rail: the same event must not move the frame further.
    let before = panel.frame
    panel.scrollWheel(with: ev)
    XCTAssertEqual(panel.frame, before)
  }

  private func scrollEvent(wheel1: Int32) -> NSEvent? {
    guard let cg = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
      wheel1: wheel1, wheel2: 0, wheel3: 0)
    else { return nil }
    return NSEvent(cgEvent: cg)
  }
}
