import ApplicationServices
import AppKit

/// Private SPI: the CGWindowID backing an AXUIElement window. Used only to key a
/// live AX element back to the freeze-time snappable-window list for the
/// divergence metric. Acceptable for a notarized-DMG distribution (NOT the App
/// Store) — see the phase8 distribution note. Returns .success on success.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(
  _ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Accessibility (AX) element snap support for the screenshot overlay's
/// experimental "precise element snap" mode. All queries are SYNCHRONOUS AX
/// round-trips to the target app's main thread, so callers MUST invoke [query]
/// on a background queue with the short messaging timeout it installs; a hung
/// target then degrades to nil (the caller falls back to window snap) instead of
/// freezing the overlay.
enum ElementSnap {
  /// Whether the app currently holds the macOS Accessibility permission.
  static func trusted() -> Bool { AXIsProcessTrusted() }

  /// Prompt for Accessibility permission (system dialog / System Settings deep
  /// link). The option key's value is the stable string "AXTrustedCheckOptionPrompt"
  /// — used as a literal to sidestep the Unmanaged<CFString>-vs-CFString SDK skew.
  static func requestTrust() {
    let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
  }

  private static let kMinSide: CGFloat = 24

  /// The element at a GLOBAL top-left screen point. [walk]: 0 = at the point,
  /// +N = N levels up the ancestry (grow), -N = N levels down toward the point
  /// (shrink). [displayOrigin] maps the result back to display-local logical
  /// (top-left). Returns the channel dict or nil (not trusted / timed out / no
  /// element / no frame / nothing but our own overlay under the point).
  static func query(globalTopLeft pt: CGPoint, walk: Int,
                    displayOrigin: CGPoint) -> [String: Any]? {
    let t0 = DispatchTime.now()

    // CRITICAL: the freeze overlay is a full-screen TOPMOST window, so a
    // system-wide hit-test (AXUIElementCopyElementAtPosition on the system-wide
    // element) would always return OUR OWN overlay element (a full-screen rect).
    // Instead, resolve the frontmost NON-Glimpr window under the point and query
    // THAT app's AX element directly — it ignores whatever is layered on top.
    guard let pid = targetPID(at: pt) else { return nil }
    let app = AXUIElementCreateApplication(pid)
    // Bound every AX message to this app so a hung target can't stall us.
    AXUIElementSetMessagingTimeout(app, 0.12)

    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(app, Float(pt.x), Float(pt.y), &hit)
            == .success, var el = hit else { return nil }

    // Climb out of sub-minimum noise to the first sensibly-sized element.
    el = sensible(el)
    // Apply the tree walk, counting how many levels ACTUALLY moved (it stops at
    // the real root/leaf). Dart syncs its counter to this so it can't overshoot
    // the real tree depth — otherwise reversing direction has a dead zone.
    var applied = 0
    if walk > 0 {
      for _ in 0..<walk {
        guard let p = parent(el) else { break }
        el = p
        applied += 1
      }
    } else if walk < 0 {
      for _ in 0..<(-walk) {
        guard let ch = child(el, at: pt) else { break }
        el = ch
        applied -= 1
      }
    }

    guard let f = frame(el) else { return nil }
    let latUs =
      (DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1000

    var out: [String: Any] = [
      "x": Double(f.minX - displayOrigin.x),
      "y": Double(f.minY - displayOrigin.y),
      "w": Double(f.width),
      "h": Double(f.height),
      "role": stringAttr(el, kAXRoleAttribute) ?? "",
      "title": stringAttr(el, kAXTitleAttribute)
        ?? stringAttr(el, kAXDescriptionAttribute) ?? "",
      "app": appName(of: el) ?? "",
      "latencyUs": Int(latUs),
      "appliedWalk": applied,
    ]
    if let win = window(of: el), let wf = frame(win) {
      out["winX"] = Double(wf.minX - displayOrigin.x)
      out["winY"] = Double(wf.minY - displayOrigin.y)
      out["winW"] = Double(wf.width)
      out["winH"] = Double(wf.height)
      var wid: CGWindowID = 0
      if _AXUIElementGetWindow(win, &wid) == .success { out["windowId"] = Int(wid) }
    }
    return out
  }

  // MARK: - AX helpers

  // The layers element snap targets: the shared snappableWindowLevels set
  // ({0, 3, 8}). Higher layers (Dock/notifications/menus, the Window Server
  // cursor at ~2.1e9, our overlay) are EXCLUDED: they are a poor fit for a
  // live-AX-over-frozen-image snap — MENUS close on the screenshot trigger, so
  // the live AX tree no longer has them even though the freeze captured them;
  // NOTIFICATIONS need a full-screen backing container whose PID would shadow
  // every point; the cursor window sits at the cursor and shadowed every
  // query. Owner reverted high-layer support 2026-06-16.
  static let appLevels = ScreenCapturer.snappableWindowLevels

  /// The owning PID to AX-query for the frontmost snappable window (layers
  /// {0,3,8}, visible) under [pt]. Our OWN windows are NOT skipped past: if our
  /// window is the visual top under the point, return nil so Dart whole-window-
  /// snaps it (the topmost overlay shadows our own AX tree, so an element query
  /// can't reach it) — matching the non-AX window-snap path, which also includes
  /// our own Settings/editor windows. Do NOT peer at the app BEHIND our window;
  /// our window is the target. The overlay itself is excluded by the layer filter
  /// (shielding level), the warm control window by the alpha filter. AX-only:
  /// without the permission the query returns nil and falls back to window snap,
  /// so this is inert until granted.
  private static func targetPID(at pt: CGPoint) -> pid_t? {
    guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let selfPID = getpid()
    for w in infos { // front-to-back
      guard let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
            alpha > 0.05,
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
            appLevels.contains(layer),
            let r = ScreenCapturer.windowBounds(w),
            let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
      else { continue }
      guard r.contains(pt) else { continue }
      // First snappable window under the point = the visual top. If it's ours,
      // nil -> Dart whole-window snap; otherwise AX-query that app.
      return pid == selfPID ? nil : pid
    }
    return nil
  }

  /// Walk up until the element has a sensible on-screen size (or we run out).
  private static func sensible(_ e: AXUIElement) -> AXUIElement {
    var cur = e
    for _ in 0..<24 {
      if let f = frame(cur), f.width >= kMinSide, f.height >= kMinSide { return cur }
      guard let p = parent(cur) else { return cur }
      cur = p
    }
    return cur
  }

  /// Element frame from AXPosition + AXSize (both public, top-left global points).
  private static func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = pointAttr(e, kAXPositionAttribute),
          let s = sizeAttr(e, kAXSizeAttribute) else { return nil }
    return CGRect(origin: p, size: s)
  }

  private static func pointAttr(_ e: AXUIElement, _ attr: String) -> CGPoint? {
    guard let v = axValue(e, attr) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v, .cgPoint, &p) ? p : nil
  }

  private static func sizeAttr(_ e: AXUIElement, _ attr: String) -> CGSize? {
    guard let v = axValue(e, attr) else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v, .cgSize, &s) ? s : nil
  }

  private static func axValue(_ e: AXUIElement, _ attr: String) -> AXValue? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success,
          let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
    return (val as! AXValue)
  }

  private static func parent(_ e: AXUIElement) -> AXUIElement? {
    element(e, kAXParentAttribute)
  }

  /// The first child whose frame contains [pt] (toward the cursor on walk-down).
  private static func child(_ e: AXUIElement, at pt: CGPoint) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
            == .success, let arr = v as? [AXUIElement] else { return nil }
    for c in arr { if let f = frame(c), f.contains(pt) { return c } }
    return nil
  }

  /// The owning window element: the AXWindow attribute, else climb to an
  /// AXWindow-role ancestor.
  private static func window(of e: AXUIElement) -> AXUIElement? {
    if let w = element(e, kAXWindowAttribute) { return w }
    var cur: AXUIElement? = e
    for _ in 0..<24 {
      guard let c = cur else { break }
      if stringAttr(c, kAXRoleAttribute) == (kAXWindowRole as String) { return c }
      cur = parent(c)
    }
    return nil
  }

  private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success,
          let val = v, CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
    return (val as! AXUIElement)
  }

  private static func stringAttr(_ e: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success
    else { return nil }
    return v as? String
  }

  private static func appName(of e: AXUIElement) -> String? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(e, &pid) == .success else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.localizedName
  }
}
