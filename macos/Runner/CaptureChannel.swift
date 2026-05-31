import Cocoa
import FlutterMacOS
import ScreenCaptureKit
import CoreGraphics

/// Registers `glimpr/capture` and serves `captureAllDisplays`.
final class CaptureChannel {
  private let channel: FlutterMethodChannel
  private var cachedContent: SCShareableContent?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "glimpr/capture", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "captureAllDisplays":
        self.captureAllDisplays(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    refreshCache()
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main) { [weak self] _ in self?.refreshCache() }
  }

  private func refreshCache() {
    SCShareableContent.getWithCompletionHandler { content, _ in
      self.cachedContent = content
    }
  }

  private func captureAllDisplays(result: @escaping FlutterResult) {
    if !CGPreflightScreenCaptureAccess() {
      CGRequestScreenCaptureAccess()
      result(FlutterError(code: "permissionDenied",
                          message: "Screen Recording permission is required. Enable it in System Settings > Privacy & Security > Screen Recording, then relaunch.",
                          details: nil))
      return
    }
    Task {
      do {
        let content: SCShareableContent
        if let cached = self.cachedContent {
          content = cached
        } else {
          content = try await SCShareableContent.current
        }
        self.cachedContent = content
        let displays = content.displays
        if displays.isEmpty {
          DispatchQueue.main.async { result(FlutterError(code: "noDisplays", message: "No displays found", details: nil)) }
          return
        }
        let cursor = NSEvent.mouseLocation
        var out: [[String: Any]] = []
        for d in displays {
          let scale = self.scaleFactor(for: d.displayID)
          let cfg = SCStreamConfiguration()
          cfg.width = Int(CGFloat(d.width) * scale)
          cfg.height = Int(CGFloat(d.height) * scale)
          cfg.showsCursor = false
          let filter = SCContentFilter(display: d, excludingWindows: [])
          let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
          guard let png = self.pngData(from: cgImage) else { continue }
          let frame = d.frame
          let inDisplay = NSPointInRect(NSPoint(x: cursor.x, y: cursor.y), self.flipToBottomLeft(frame))
          out.append([
            "displayId": Int(d.displayID),
            "pngBytes": FlutterStandardTypedData(bytes: png),
            "left": Double(frame.origin.x),
            "top": Double(frame.origin.y),
            "width": Double(frame.size.width),
            "height": Double(frame.size.height),
            "scaleFactor": Double(scale),
            "isCursorDisplay": inDisplay,
          ])
        }
        DispatchQueue.main.async { result(out) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "captureError", message: "\(error)", details: nil)) }
      }
    }
  }

  private func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
    for screen in NSScreen.screens {
      if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
         num.uint32Value == displayID {
        return screen.backingScaleFactor
      }
    }
    return 1.0
  }

  private func flipToBottomLeft(_ frame: CGRect) -> NSRect {
    let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? frame.maxY
    return NSRect(x: frame.origin.x, y: totalHeight - frame.origin.y - frame.size.height,
                  width: frame.size.width, height: frame.size.height)
  }

  private func pngData(from cgImage: CGImage) -> Data? {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
  }
}
