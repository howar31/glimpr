import 'package:flutter/services.dart';
import '../settings/app_locale.dart';
import 'captured_display.dart';
import 'element_snap.dart';

/// Dart-side facade over the native `glimpr/capture` MethodChannel.
class CaptureBridge {
  static const _channel = MethodChannel('glimpr/capture');
  static const _overlay = MethodChannel('glimpr/overlay');

  /// Trigger the overlay capture flow (native captures + pushes + shows).
  /// [pinOnly]: the "capture to pin" mode — the session's confirm runs ONLY
  /// the pin action instead of the configured after-capture flow.
  /// [liveSelect]: a RECORDING live-select session — no capture; the overlay
  /// presents transparent over the live screen and confirm starts a recording.
  Future<void> beginCapture({bool pinOnly = false, bool liveSelect = false}) =>
      _channel.invokeMethod(
          'beginCapture', {'pinOnly': pinOnly, 'liveSelect': liveSelect});

  /// Live-select loupe pixels: a span×span RGBA8888 patch centered on the
  /// NATIVE pixel (x, y) of THIS engine's display, or null before the live
  /// stream delivers its first frame.
  Future<Uint8List?> loupeSample(int x, int y, int span) async {
    final res = await _channel
        .invokeMethod('loupeSample', {'x': x, 'y': y, 'span': span});
    return res as Uint8List?;
  }

  /// Live-select confirm/cancel: relays the chosen recording REGION to the
  /// control engine's record controller. Region recording always records a
  /// fixed rectangle (a snap commits the window's own rect), so no window id
  /// is relayed. Null [rect] = whole display; [cancelled] aborts.
  Future<void> recordSelection({
    required int displayId,
    Rect? rect,
    String? title,
    String? app,
    // One-shot per-recording overrides (toolbar toggles); null = use the
    // persisted Recording settings.
    bool? showsCursor,
    bool? systemAudio,
    bool? microphone,
    bool? hevc,
    bool? hdr,
    bool? gif,
    int? fps,
    int? gifFps,
    int? maxDuration,
    bool cancelled = false,
  }) =>
      _channel.invokeMethod('recordSelection', {
        'displayId': displayId,
        if (rect != null) ...{
          'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height,
        },
        'title': ?title,
        'app': ?app,
        'showsCursor': ?showsCursor,
        'systemAudio': ?systemAudio,
        'microphone': ?microphone,
        'hevc': ?hevc,
        'hdr': ?hdr,
        'gif': ?gif,
        'fps': ?fps,
        'gifFps': ?gifFps,
        'maxDuration': ?maxDuration,
        'cancelled': cancelled,
      });

  /// Native single-target capture for the direct (non-interactive) modes:
  /// the cursor display when [displayId] is null, cropped to [rect]
  /// (display-local logical points) when given, encoded natively (PNG, or
  /// JPEG at [jpegQuality]). Null when the requested display is not present.
  Future<RegionCapture?> captureRegion({
    int? displayId,
    Rect? rect,
    bool showsCursor = false,
    bool jpeg = false,
    int jpegQuality = 90,
    Map<String, dynamic>? decoration,
    // Also return the UNDECORATED rendition (plainBytes) when decorating —
    // the flow's pin leg always consumes the plain capture.
    bool alsoPlain = false,
    // Dual-output HDR: when the captured display is HDR, also return the
    // undecorated HDR rendition (hdrBytes + hdrExt) beside the SDR bytes.
    bool hdr = false,
  }) async {
    final res = await _channel.invokeMethod('captureRegion', {
      'displayId': ?displayId,
      if (rect != null) ...{
        'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height,
      },
      'showsCursor': showsCursor,
      'jpeg': jpeg,
      'quality': jpegQuality,
      'decoration': ?decoration,
      'alsoPlain': alsoPlain,
      'hdr': hdr,
    });
    if (res == null) return null;
    return RegionCapture.fromMap((res as Map).cast<dynamic, dynamic>());
  }

  /// Live AX element under the display-local LOGICAL point (top-left origin) on
  /// [displayId]. [walk]: 0 = the element at the point; +N = N levels up the
  /// ancestry; -N = N levels down toward the point. Null when AX is off / not
  /// trusted / the query timed out / no element — the caller falls back to the
  /// static window snap. Runs natively on a background queue (short messaging
  /// timeout) so a hung target app degrades to null, never blocks the overlay.
  Future<ElementSnap?> elementSnapAt(int displayId, double x, double y,
      {int walk = 0}) async {
    try {
      final res = await _channel.invokeMethod('elementSnapAt',
          {'displayId': displayId, 'x': x, 'y': y, 'walk': walk});
      if (res == null) return null;
      return ElementSnap.fromMap((res as Map).cast<dynamic, dynamic>());
    } catch (_) {
      return null; // absent in tests / non-overlay engines
    }
  }

  /// Whether the app currently holds the macOS Accessibility (AX) permission.
  Future<bool> accessibilityTrusted() async {
    try {
      return (await _channel.invokeMethod('accessibilityTrusted')) as bool? ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Prompt for Accessibility permission (system dialog / opens System Settings
  /// ▸ Privacy & Security ▸ Accessibility). Fire-and-forget.
  Future<void> requestAccessibility() async {
    try {
      await _channel.invokeMethod('requestAccessibility');
    } catch (_) {
      // Absent in tests / non-control engines.
    }
  }

  /// The frontmost focused window's display-local rect + names, or null if none.
  Future<FocusedWindowInfo?> focusedWindow() async {
    final res = await _channel.invokeMethod('focusedWindow');
    if (res == null) return null;
    return FocusedWindowInfo.fromMap((res as Map).cast<dynamic, dynamic>());
  }

  /// The overlay snap MASK: a window's raw alpha shape (BGRA8888), or null when
  /// no such window / the native capture failed -> the caller drops the mask
  /// and uses a rectangular crop.
  Future<WindowImage?> captureWindowImage(
    int windowId, {
    bool showsCursor = false,
  }) async {
    final res = await _channel.invokeMethod(
      'captureWindowImage',
      {'windowId': windowId, 'showsCursor': showsCursor},
    );
    if (res == null) return null;
    return WindowImage.fromMap((res as Map).cast<dynamic, dynamic>());
  }

  /// Direct "Capture Window": the FINAL encoded bytes (PNG, or JPEG at
  /// [jpegQuality]), optionally decorated natively via [decoration] (a logical
  /// spec; native scales by the window's display scale). [alsoPlain] requests
  /// the UNDECORATED sibling rendition for the flow's pin leg. Null when no
  /// such window / the native capture failed -> the caller falls back to a
  /// rect crop.
  Future<
      ({
        Uint8List bytes,
        Uint8List? plainBytes,
        Uint8List? hdrBytes,
        String? hdrExt,
      })?> captureWindowDelivered(
    int windowId, {
    bool showsCursor = false,
    bool jpeg = false,
    int jpegQuality = 90,
    Map<String, dynamic>? decoration,
    bool alsoPlain = false,
    bool hdr = false,
  }) async {
    final res = await _channel.invokeMethod('captureWindowDelivered', {
      'windowId': windowId,
      'showsCursor': showsCursor,
      'jpeg': jpeg,
      'quality': jpegQuality,
      'decoration': ?decoration,
      'alsoPlain': alsoPlain,
      'hdr': hdr,
    });
    if (res == null) return null;
    final m = res as Map;
    final bytes = m['bytes'] as Uint8List?;
    if (bytes == null) return null;
    return (
      bytes: bytes,
      plainBytes: m['plainBytes'] as Uint8List?,
      hdrBytes: m['hdrBytes'] as Uint8List?,
      hdrExt: m['hdrExt'] as String?,
    );
  }

  /// Composite + encode the HDR rendition of an annotated overlay export from
  /// the natively-retained HDR base (freeze-time fp16/EDR). [items] is the
  /// ordered overlay-segment / effect-op list from buildHdrExportItems; [crop]
  /// is the FRAME-space native px crop. Returns null when no HDR base is
  /// retained for [displayId]/[gen] (SDR-only display, setting off at freeze,
  /// or a stale layer) — the caller just skips the HDR sibling.
  Future<({Uint8List bytes, String ext})?> encodeHdrRegion({
    required int displayId,
    required int gen,
    required Rect crop,
    required List<Map<String, dynamic>> items,
    Uint8List? maskBytes,
    int maskW = 0,
    int maskH = 0,
    int maskRowBytes = 0,
  }) async {
    try {
      final res = await _channel.invokeMethod('encodeHdrRegion', {
        'displayId': displayId,
        'gen': gen,
        'x': crop.left, 'y': crop.top, 'w': crop.width, 'h': crop.height,
        'items': items,
        'mask': ?maskBytes,
        'maskW': maskW,
        'maskH': maskH,
        'maskRowBytes': maskRowBytes,
      });
      if (res == null) return null;
      final m = res as Map;
      final bytes = m['bytes'] as Uint8List?;
      final ext = m['ext'] as String?;
      if (bytes == null || ext == null) return null;
      return (bytes: bytes, ext: ext);
    } catch (_) {
      return null; // handler absent (tests / older native) -> no HDR sibling
    }
  }

  /// Hide all overlay windows and release buffers (Esc-cancel or capture-fire).
  Future<void> dismissOverlay() => _channel.invokeMethod('dismissOverlay');

  /// Stop the record-select loupe's live-pixel SCStreams WITHOUT hiding the
  /// overlay window — used when a record-select picker is torn down over a
  /// session beneath (which keeps the window up, so dismissOverlay is skipped).
  /// Idempotent on the native side; the next record-select restarts the feed.
  Future<void> stopLoupeFeed() => _channel.invokeMethod('stopLoupeFeed');

  /// Hide ONLY this engine's overlay window (a layer pop restored a layer this
  /// display has no frame for). The session itself keeps running.
  Future<void> hideOverlayWindow() => _channel.invokeMethod('hideOverlay');

  /// Open [path] in the standalone image editor — the after-capture flow's
  /// "open in editor" leg. Static because the flow runner calls it without a
  /// bridge instance; both the control and overlay engines' native `glimpr/
  /// capture` handlers route it to the warm editor window.
  static Future<void> openInEditor(String path) =>
      _channel.invokeMethod('openInEditor', {'path': path});

  /// Show the macOS share sheet for the file at [path] — the completion flow's
  /// shareSheet leg. Anchored natively: image editor window when visible, else
  /// the menu-bar status item. Static for the same reason as [openInEditor].
  /// NOTE: the image editor engine routes this over its own channel instead
  /// (it has no glimpr/capture handler) — see image_editor_app's shareFn.
  static Future<void> shareSheet(String path) =>
      _channel.invokeMethod('shareSheet', {'path': path});

  /// Pin the image at [path] as a floating always-on-top window — the flow's
  /// pin leg. [globalRect] (GLOBAL top-left logical) pins it in place over
  /// where it was captured; null centers it at the image's logical size.
  /// Static for the same reason as [openInEditor]; the editor engine routes
  /// over its own channel instead.
  static Future<void> pinImage(String path, {Rect? globalRect}) =>
      _channel.invokeMethod('pinImage', {
        'path': path,
        if (globalRect != null) ...{
          'x': globalRect.left,
          'y': globalRect.top,
          'w': globalRect.width,
          'h': globalRect.height,
        },
      });

  /// A capture flow just recorded a saved file into the shared recent-images
  /// store — ask native to forward a refresh to the editor engine (it owns the
  /// landing gallery and the menu-bar "Open Recent" submenu). Static for the
  /// same reason as [openInEditor].
  static Future<void> notifyRecentChanged() =>
      _channel.invokeMethod('recentChanged');

  /// Drive the menu-bar "processing" pulse: true at capture commit (the shutter
  /// moment), false once the output is delivered. Purely visual (independent of
  /// the shutter-sound setting). Fire-and-forget. From the overlay engine this
  /// relays to the control engine's status item. The label becomes the pulsing
  /// icon's hover tooltip (what is being processed).
  static Future<void> setCaptureProcessing(bool active) async {
    try {
      await _channel.invokeMethod('setProcessing', {
        'active': active,
        'label': appL10n.trayProcessingScreenshot,
      });
    } catch (_) {
      // Fire-and-forget; absent in tests / other engines.
    }
  }

  /// Drop a named perf mark into the NATIVE perf log (macOS: unified log
  /// subsystem com.howar31.glimpr, category "perf"; Windows: the debug-gated
  /// %APPDATA% perf.log) so Dart-side completion events land on the same
  /// timeline as the native capture marks. Static for the same reason as
  /// [openInEditor]. Fire-and-forget; absent in tests / stub engines.
  static Future<void> perfMark(String label) async {
    try {
      await _channel.invokeMethod('perfMark', {'label': label});
    } catch (_) {
      // Fire-and-forget.
    }
  }

  /// Reveal the Settings window (⌘, from the capture overlay). The caller
  /// dismisses the overlay first, since it sits above normal windows.
  Future<void> openSettings() => _channel.invokeMethod('openSettings');

  /// Show a native error alert — used when a BACKGROUND export fails after the
  /// overlay was already hidden (so the in-overlay toast is no longer available).
  /// Fire-and-forget: never throws (absent in tests / stub engines).
  Future<void> showError(String message) async {
    try {
      await _channel.invokeMethod('showError', {'message': message});
    } catch (_) {
      // Fire-and-forget.
    }
  }

  /// Signal that this overlay engine has rasterized its first frame, so native
  /// may order its window front (capture-then-show).
  Future<void> overlayReady() => _channel.invokeMethod('overlayReady');

  /// Hide / show the system cursor (the active editor engine drives this — hidden
  /// over the canvas where we draw our own crosshair/reticle, shown over the
  /// toolbar). Native keeps it balanced and always restores it on dismiss.
  Future<void> setCursorHidden(bool hidden) =>
      _channel.invokeMethod('setCursorHidden', {'hidden': hidden});

  /// Confine the cursor to this display while a draw/crop drag runs (and freeze
  /// the cross-display active handoff), so a stroke can't be broken by the cursor
  /// wandering onto another display. Released when the drag ends.
  Future<void> setDrawingLock(bool locked) =>
      _channel.invokeMethod('setDrawingLock', {'locked': locked});

  /// Broadcast the active tool + style to the OTHER displays' editors so the
  /// tool/colour/width/font stay in sync across displays.
  Future<void> broadcastEditorState(Map<String, dynamic> state) =>
      _channel.invokeMethod('broadcastEditorState', state);

  /// Record hotkey pressed while a record-select is in flight: native relays it
  /// to every overlay engine (each resurfaces a suspended picker or cancels a
  /// foreground one). Called from the control engine's RecordController.
  Future<void> recordSelectHotkey() =>
      _channel.invokeMethod('recordSelectHotkey');

  /// Warp the OS mouse cursor to a GLOBAL display point (top-left origin,
  /// logical points) so keyboard nudges move the real pointer, not just the
  /// selection (otherwise the next mouse move resets the nudge).
  Future<void> warpCursor(double x, double y) =>
      _channel.invokeMethod('warpCursor', {'x': x, 'y': y});

  /// Register native -> Dart overlay callbacks. Call once per engine at startup.
  void registerOverlayHandlers({
    required void Function(
            CapturedDisplay display, bool pinOnly, bool liveSelect)
        onCaptureReady,
    required void Function(String reason, String message) onCaptureFailed,
    void Function(int activeId, Offset cursor)? onActiveDisplay,
    void Function(Map<String, dynamic> state)? onEditorState,
    void Function()? onSettingsOpen,
    void Function()? onResume,
    void Function()? onRecordSelectHotkey,
  }) {
    _overlay.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onCaptureReady':
          final args = (call.arguments as Map);
          final map = (args['display'] as Map).cast<dynamic, dynamic>();
          onCaptureReady(
            CapturedDisplay.fromMap(map),
            (args['pinOnly'] as bool?) ?? false,
            (args['liveSelect'] as bool?) ?? false,
          );
          return null;
        case 'onCaptureFailed':
          final args = (call.arguments as Map);
          onCaptureFailed(
            args['reason'] as String,
            (args['message'] as String?) ?? '',
          );
          return null;
        case 'onActiveDisplay':
          // The cursor poll picked the active display for ALL engines. This one
          // shows its HUD only when activeId == its own display id.
          final a = (call.arguments as Map);
          onActiveDisplay?.call(
            a['activeId'] as int,
            Offset(
              (a['cursorX'] as num).toDouble(),
              (a['cursorY'] as num).toDouble(),
            ),
          );
          return null;
        case 'onEditorState':
          // Another display changed tool/style -> mirror it here.
          onEditorState?.call((call.arguments as Map).cast<String, dynamic>());
          return null;
        case 'onSettingsOpen':
          // ⌘, paused this freeze for Settings -> show the dim mask.
          onSettingsOpen?.call();
          return null;
        case 'onResume':
          // The freeze was resumed after a ⌘, Settings detour -> drop the mask +
          // re-read settings.
          onResume?.call();
          return null;
        case 'onRecordSelectHotkey':
          // Record hotkey while a record-select is in flight: resurface or cancel.
          onRecordSelectHotkey?.call();
          return null;
        default:
          return null; // onWindowsRefreshed etc. are Phase 4 — ignore.
      }
    });
  }
}
