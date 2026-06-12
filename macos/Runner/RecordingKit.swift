import AVFoundation
import Cocoa
import FlutterMacOS
import ScreenCaptureKit

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

/// The on-screen recording chrome: a border window outlining the recorded
/// region (region/window modes) and a control strip (timer + file size + Stop
/// / Abort). Display mode shows only the strip as a draggable HUD. Every
/// window here is listed in the capture filter's exclusions — chrome never
/// appears in the output (chrome vs content: Glimpr's Settings/editor windows
/// DO record).
@MainActor
final class RecordingChrome {
  private var borderWindow: NSWindow?
  private var stripWindow: NSWindow?
  private let timerLabel = NSTextField(labelWithString: "00:00")
  private let sizeLabel = NSTextField(labelWithString: "0 MB")
  var onStop: (() -> Void)?
  var onAbort: (() -> Void)?

  /// All chrome windows, for the SCContentFilter exclusion list.
  var windowNumbers: [Int] {
    [borderWindow, stripWindow].compactMap { $0?.windowNumber }
  }

  /// [regionGlobalBottomLeft] is in Cocoa GLOBAL (bottom-left) coords; nil =
  /// display mode (no border; strip parks at the screen's top-right).
  func show(regionGlobalBottomLeft: NSRect?, on screen: NSScreen) {
    if let region = regionGlobalBottomLeft {
      let b = borderlessWindow(
        frame: region.insetBy(dx: -2, dy: -2), level: .statusBar)
      b.ignoresMouseEvents = true
      let v = NSView(frame: NSRect(origin: .zero, size: b.frame.size))
      v.wantsLayer = true
      v.layer?.borderColor = NSColor.systemRed.cgColor
      v.layer?.borderWidth = 2
      b.contentView = v
      b.orderFrontRegardless()
      borderWindow = b
    }
    let strip = buildStrip()
    let stripSize = strip.frame.size
    let origin: NSPoint
    if let region = regionGlobalBottomLeft {
      // Prefer below the region (visually under it = lower y), flip above
      // when there is no room, clamp inside the screen.
      var x = region.minX
      var y = region.minY - stripSize.height - 8
      if y < screen.visibleFrame.minY { y = region.maxY + 8 }
      x = min(max(screen.visibleFrame.minX + 4, x),
              screen.visibleFrame.maxX - stripSize.width - 4)
      origin = NSPoint(x: x, y: y)
    } else {
      origin = NSPoint(
        x: screen.visibleFrame.maxX - stripSize.width - 16,
        y: screen.visibleFrame.maxY - stripSize.height - 16)
      strip.isMovableByWindowBackground = true
    }
    strip.setFrameOrigin(origin)
    strip.orderFrontRegardless()
    stripWindow = strip
  }

  func update(duration: CMTime, fileSize: Int) {
    let s = Int(duration.seconds.rounded(.down))
    timerLabel.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
    sizeLabel.stringValue = String(format: "%.1f MB", Double(fileSize) / 1_048_576)
  }

  func dismiss() {
    borderWindow?.orderOut(nil)
    stripWindow?.orderOut(nil)
    borderWindow = nil
    stripWindow = nil
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
    let height: CGFloat = 34
    let dot = NSView(frame: NSRect(x: 10, y: (height - 8) / 2, width: 8, height: 8))
    dot.wantsLayer = true
    dot.layer?.backgroundColor = NSColor.systemRed.cgColor
    dot.layer?.cornerRadius = 4

    for label in [timerLabel, sizeLabel] {
      label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
      label.textColor = .white
      label.sizeToFit()
    }
    timerLabel.stringValue = "00:00"
    sizeLabel.stringValue = "0.0 MB"

    let stop = NSButton(
      title: L.s("Stop", "停止"), target: self, action: #selector(stopTapped))
    let abort = NSButton(
      title: L.s("Abort", "取消"), target: self, action: #selector(abortTapped))
    for b in [stop, abort] {
      b.bezelStyle = .accessoryBarAction
      b.controlSize = .small
      b.sizeToFit()
    }

    // Manual row layout: dot · timer · size · stop · abort.
    var x: CGFloat = 26
    func place(_ v: NSView) {
      var f = v.frame
      f.origin = NSPoint(x: x, y: (height - f.height) / 2)
      v.frame = f
      x = f.maxX + 10
    }
    place(timerLabel)
    place(sizeLabel)
    place(stop)
    place(abort)

    let w = borderlessWindow(
      frame: NSRect(x: 0, y: 0, width: x, height: height), level: .statusBar)
    let content = NSView(frame: w.frame)
    content.wantsLayer = true
    content.layer?.backgroundColor =
      NSColor.black.withAlphaComponent(0.75).cgColor
    content.layer?.cornerRadius = 8
    for v in [dot, timerLabel, sizeLabel, stop, abort] { content.addSubview(v) }
    w.contentView = content
    return w
  }

  @objc private func stopTapped() { onStop?() }
  @objc private func abortTapped() { onAbort?() }
}

// MARK: - RecordingController

/// Owns one recording session: SCStream + SCRecordingOutput straight to the
/// final .mp4 (no FFmpeg, no temp/remux). All recording native code lives
/// behind the `glimpr/record` seam — the existing capture path is untouched.
@available(macOS 15.0, *)
@MainActor
final class RecordingController: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
  struct Spec {
    let mode: String // region | window | display | lastRegion
    let displayID: CGDirectDisplayID?
    let rect: CGRect? // display-local top-left logical points
    let windowID: CGWindowID?
    let fps: Int
    let hevc: Bool
    let showsCursor: Bool
    let systemAudio: Bool
    let microphone: Bool
    let outputPath: String
  }

  private(set) var isRecording = false
  private var stream: SCStream?
  private var output: SCRecordingOutput?
  private var chrome: RecordingChrome?
  private var tick: Timer?
  private var outputPath: String?
  private var abortRequested = false
  private var events: (String, Any?) -> Void
  var onStateChange: ((Bool) -> Void)?

  init(events: @escaping (String, Any?) -> Void) {
    self.events = events
  }

  func start(_ spec: Spec) async {
    guard !isRecording, stream == nil else {
      events("onRecordFailed", ["message": "already recording"])
      return
    }
    do {
      let content = try await SCShareableContent.current

      let filter: SCContentFilter
      var chromeRegionGlobal: NSRect? // Cocoa global bottom-left, for chrome
      var screen: NSScreen
      let scale: CGFloat

      if spec.mode == "window", let wid = spec.windowID {
        guard let scWindow = content.windows.first(where: { $0.windowID == wid })
        else { throw RecordingError.message("window not found") }
        filter = SCContentFilter(desktopIndependentWindow: scWindow)
        scale = CGFloat(filter.pointPixelScale)
        screen = NSScreen.main ?? NSScreen.screens[0]
        // The window stream follows the window; no border chrome (it would
        // not track moves) — strip only, parked top-right like display mode.
        chromeRegionGlobal = nil
      } else {
        let displayID = spec.displayID ?? Self.cursorDisplayID()
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }),
              let nsScreen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                  as? NSNumber)?.uint32Value == displayID
              })
        else { throw RecordingError.message("display not found") }
        screen = nsScreen
        scale = nsScreen.backingScaleFactor

        // Chrome FIRST, so its windows exist in shareable content for the
        // exclusion list (chrome never records; Glimpr content windows do).
        let c = RecordingChrome()
        if let r = spec.rect {
          // top-left display-local -> Cocoa global bottom-left
          let global = NSRect(
            x: nsScreen.frame.minX + r.minX,
            y: nsScreen.frame.maxY - r.maxY,
            width: r.width, height: r.height)
          chromeRegionGlobal = global
        }
        c.show(regionGlobalBottomLeft: chromeRegionGlobal, on: nsScreen)
        chrome = c
        let excludedNumbers = c.windowNumbers
        let fresh = try await SCShareableContent.current
        let excluded = fresh.windows.filter {
          excludedNumbers.contains(Int($0.windowID))
        }
        filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
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
      if spec.systemAudio {
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
      }
      if spec.microphone {
        cfg.captureMicrophone = true
      }

      let outConfig = SCRecordingOutputConfiguration()
      outConfig.outputURL = URL(fileURLWithPath: spec.outputPath)
      outConfig.videoCodecType = spec.hevc ? .hevc : .h264
      outConfig.outputFileType = .mp4
      let out = SCRecordingOutput(configuration: outConfig, delegate: self)

      let s = SCStream(filter: filter, configuration: cfg, delegate: self)
      try s.addRecordingOutput(out)
      try await s.startCapture()

      // Window mode shows its strip only now (no exclusion needed: the
      // window filter records that window alone, the strip can't appear).
      if spec.mode == "window", chrome == nil {
        let c = RecordingChrome()
        c.show(regionGlobalBottomLeft: nil, on: screen)
        chrome = c
      }
      chrome?.onStop = { [weak self] in Task { await self?.stop() } }
      chrome?.onAbort = { [weak self] in Task { await self?.abort() } }

      stream = s
      output = out
      outputPath = spec.outputPath
      abortRequested = false
      isRecording = true
      onStateChange?(true)
      startTick()
      PerfLog.mark("recordStart mode=\(spec.mode)")
      events("onRecordStarted", [
        "displayId": Int(spec.displayID ?? 0),
        "x": Double(spec.rect?.minX ?? 0), "y": Double(spec.rect?.minY ?? 0),
        "w": Double(spec.rect?.width ?? 0), "h": Double(spec.rect?.height ?? 0),
      ])
    } catch {
      cleanupSession()
      events("onRecordFailed", ["message": "\(error)"])
    }
  }

  func stop() async {
    guard isRecording, let s = stream else { return }
    isRecording = false // block double-stops; delegate finishes the teardown
    do {
      try await s.stopCapture()
    } catch {
      // The file may still have finalized; the delegate decides. A hard
      // failure with no delegate callback still cleans up below.
      finishedRecording(error: error)
      return
    }
  }

  func abort() async {
    abortRequested = true
    await stop()
  }

  // MARK: SCRecordingOutputDelegate

  nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    Task { @MainActor in self.finishedRecording(error: nil) }
  }

  nonisolated func recordingOutput(
    _ recordingOutput: SCRecordingOutput, didFailWithError error: Error
  ) {
    Task { @MainActor in self.finishedRecording(error: error) }
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    Task { @MainActor in self.finishedRecording(error: error) }
  }

  private func finishedRecording(error: Error?) {
    guard stream != nil else { return } // already torn down
    let path = outputPath
    let duration = output?.recordedDuration.seconds ?? 0
    let size = output?.recordedFileSize ?? 0
    let aborted = abortRequested
    cleanupSession()
    PerfLog.mark("recordEnd aborted=\(aborted) error=\(error != nil)")
    if aborted {
      if let p = path { try? FileManager.default.removeItem(atPath: p) }
      events("onRecordAborted", nil)
    } else if let e = error {
      if let p = path { try? FileManager.default.removeItem(atPath: p) }
      events("onRecordFailed", ["message": "\(e)"])
    } else {
      events("onRecordFinished", [
        "path": path ?? "", "duration": duration, "fileSize": size,
      ])
    }
  }

  private func cleanupSession() {
    tick?.invalidate()
    tick = nil
    chrome?.dismiss()
    chrome = nil
    stream = nil
    output = nil
    outputPath = nil
    isRecording = false
    onStateChange?(false)
  }

  private func startTick() {
    tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        guard let self, let out = self.output else { return }
        self.chrome?.update(
          duration: out.recordedDuration, fileSize: out.recordedFileSize)
      }
    }
  }

  private static func even(_ v: Int) -> Int { max(2, v - (v % 2)) }

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
  /// Menu-bar state hook (red icon + Stop/Abort items while recording).
  var onRecordingStateChange: ((Bool) -> Void)?

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

  /// Native entries for the menu-bar Stop/Abort items.
  func stopActive() {
    if #available(macOS 15.0, *) { Task { await current()?.stop() } }
  }

  func abortActive() {
    if #available(macOS 15.0, *) { Task { await current()?.abort() } }
  }

  @available(macOS 15.0, *)
  private func current() -> RecordingController? {
    if let c = controller as? RecordingController { return c }
    let c = RecordingController(events: { [weak self] method, args in
      self?.channel.invokeMethod(method, arguments: args)
    })
    c.onStateChange = { [weak self] active in
      self?.onRecordingStateChange?(active)
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
    let showsCursor = (args["showsCursor"] as? Bool) ?? true
    let systemAudio = (args["systemAudio"] as? Bool) ?? false
    let microphone = (args["microphone"] as? Bool) ?? false
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
        fps: fps, hevc: hevc, showsCursor: showsCursor,
        systemAudio: systemAudio, microphone: microphone,
        outputPath: outputPath)
      Task { await controller.start(spec) }
    }

    // Region selection happens in the Flutter overlay's live-select session
    // (owner mandate: capture/recording share ONE selection UI); every mode
    // arrives here fully resolved.
    begin(rect: specRect(), display: displayID)
  }
}
