import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var captureChannel: CaptureChannel?
  private var captureController: CaptureController?
  private var statusItem: StatusItemController?
  private var roleChannel: FlutterMethodChannel?
  private var loginChannel: FlutterMethodChannel?
  var overlayManager: OverlayManager?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    // Frosted-glass window: host the Flutter view inside a vibrancy view
    // controller whose own view is an NSVisualEffectView (.behindWindow), so the
    // window blurs the desktop behind it; the Flutter view is transparent and
    // layers the design's translucent tint on top. IMPORTANT: do NOT set
    // window.isOpaque = false / backgroundColor = .clear — the behind-window
    // effect view drives the vibrancy itself, and forcing window transparency
    // makes the window swallow / pass through mouse events (dead UI). This recipe
    // mirrors macos_window_utils' MacOSWindowUtilsViewController. Vibrancy is a
    // stable, cross-platform-portable effect (Windows: acrylic), distinct from
    // the macOS-only Liquid Glass deliberately avoided elsewhere.
    self.contentViewController = GlassContentViewController(
      flutterViewController: flutterViewController)
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let capture = CaptureController(manager: { [weak self] in self?.overlayManager })
    self.captureController = capture
    captureChannel = CaptureChannel(
      messenger: flutterViewController.engine.binaryMessenger,
      capture: capture,
      manager: { [weak self] in self?.overlayManager }
    )

    // This window is the debug control; tell its Dart GlimprRoot which role to show.
    let roleChannel = FlutterMethodChannel(
      name: "glimpr/role", binaryMessenger: flutterViewController.engine.binaryMessenger)
    roleChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getRole": result("control")
      // Cmd-W from the settings UI: hide the window (same as the close button).
      case "closeSettings": self?.hideSettings(); result(nil)
      // Settings > Advanced: how many displays to keep warm capture-ready. Read by
      // OverlayManager ONCE at launch, so a change applies on next launch.
      case "getOverlayWarmTarget":
        result(UserDefaults.standard.object(forKey: "overlayWarmTarget") as? Int ?? 2)
      case "setOverlayWarmTarget":
        if let v = call.arguments as? Int {
          UserDefaults.standard.set(max(1, min(8, v)), forKey: "overlayWarmTarget")
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    self.roleChannel = roleChannel

    // Launch-at-login, backed by SMAppService (the OS is the source of truth).
    let loginChannel = FlutterMethodChannel(
      name: "glimpr/login", binaryMessenger: flutterViewController.engine.binaryMessenger)
    loginChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "isEnabled":
        result(SMAppService.mainApp.status == .enabled)
      case "setEnabled":
        let enable = (call.arguments as? Bool) ?? false
        do {
          if enable {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
          result(SMAppService.mainApp.status == .enabled)
        } catch {
          result(FlutterError(code: "login_item", message: "\(error)", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.loginChannel = loginChannel

    super.awakeFromNib()

    // Build + warm the per-display overlay windows/engines now (applicationDid-
    // FinishLaunching isn't reliably called in this nib setup). Each unit warms
    // its engine on-screen at alpha 0; a capture reveals the matching window.
    let manager = OverlayManager()
    manager.startObservingScreens()
    self.overlayManager = manager

    self.statusItem = StatusItemController(
      onCapture: { [weak self] in self?.captureController?.triggerCapture() },
      onSettings: { [weak self] in self?.revealSettings() })

    // Resident: keep the engine warm (on-screen, transparent, click-through) so
    // main() runs + the hotkey registers, but present nothing until "Settings…".
    // Fixed-size settings window (NOT .resizable) with an inline, transparent
    // title bar so the Flutter sidebar runs to the top edge behind the traffic
    // lights (macOS preferences style). The content lays out its own top inset.
    self.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    self.title = "Glimpr Settings"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    // Hard-lock the size. Dropping .resizable from the style mask alone proved
    // unreliable (the window is declared resizable="YES" in MainMenu.xib and the
    // mask override didn't stay applied), so clamp content min == max — AppKit
    // enforces this unconditionally, blocking edge-drag resize and window tiling.
    let fixedSize = NSSize(width: 720, height: 620)
    self.setContentSize(fixedSize)
    self.contentMinSize = fixedSize
    self.contentMaxSize = fixedSize
    // Fixed-size window: disable the green zoom / fullscreen button. This also
    // removes its window-tiling hover menu, whose modal tracking run loop blocked
    // the global capture hotkey (same-process Carbon hotkey) while it was open.
    // AppKit re-enables it on some events (e.g. regaining key after a capture),
    // so it is re-applied in revealSettings + windowDidUpdate.
    disableZoomButton()
    self.isReleasedWhenClosed = false
    self.collectionBehavior = [.moveToActiveSpace]
    self.delegate = self
    // Order front THEN drop alpha (the proven warm-engine order — same as the
    // overlay windows): an on-screen layout pass realizes the Metal surface and
    // runs main(), after which alpha 0 hides it without dropping it off-screen.
    self.orderFrontRegardless()
    self.alphaValue = 0
    self.ignoresMouseEvents = true
  }

  /// Show the settings window on the user's CURRENT Space, in front. While it is
  /// visible the app becomes a regular app (Dock icon + Cmd-Tab); it reverts to a
  /// menu-bar accessory when the window is closed (see hideSettings).
  func revealSettings() {
    NSApp.setActivationPolicy(.regular)
    alphaValue = 1
    ignoresMouseEvents = false
    center()
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    disableZoomButton()
  }

  private func hideSettings() {
    // Stay ON-SCREEN at alpha 0 (engine must remain warm — never orderOut, which
    // would drop the view off-screen and risk a blank re-show). orderBack tucks it
    // behind everything. Back to accessory: no Dock icon / not in Cmd-Tab at rest,
    // which also keeps the overlay's activate from switching Spaces during capture.
    alphaValue = 0
    ignoresMouseEvents = true
    orderBack(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideSettings()
    return false
  }

  // Belt-and-suspenders with the disabled zoom button: never zoom this window.
  func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
    false
  }

  // AppKit re-enables the zoom (green) button on various events — notably when
  // the window regains key/main focus after a capture. Re-disable it whenever the
  // window updates so it stays inert (and its tiling hover menu stays suppressed).
  func windowDidUpdate(_ notification: Notification) {
    disableZoomButton()
  }

  private func disableZoomButton() {
    standardWindowButton(.zoomButton)?.isEnabled = false
  }
}

/// Hosts the Flutter view on top of a behind-window NSVisualEffectView so the
/// settings window reads as frosted glass over the desktop. The Flutter view is
/// added as a CHILD view controller (keeping the responder chain intact so input
/// works) and made transparent so the vibrancy and the Flutter tint composite.
/// Mirrors the recipe used by macos_window_utils — crucially, the window itself
/// is left opaque (the behind-window effect view drives the vibrancy; forcing the
/// window transparent breaks mouse-event delivery).
class GlassContentViewController: NSViewController {
  private let flutterViewController: FlutterViewController

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func loadView() {
    let effectView = NSVisualEffectView()
    effectView.autoresizingMask = [.width, .height]
    effectView.blendingMode = .behindWindow
    effectView.state = .followsWindowActiveState
    effectView.material = .sidebar
    self.view = effectView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    addChild(flutterViewController)
    let flutterView = flutterViewController.view
    flutterView.frame = view.bounds
    flutterView.autoresizingMask = [.width, .height]
    // Flutter 3.7+ defaults the view background to black — clear it so the
    // vibrancy behind shows through the transparent parts of the UI.
    flutterViewController.backgroundColor = .clear
    view.addSubview(flutterView)
  }
}
