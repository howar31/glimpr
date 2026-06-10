import 'dart:typed_data';
import 'dart:ui' show Rect;

/// A snappable top-level window at capture time: its display-local logical [rect]
/// plus the window [title] and owning [app] name (for naming the saved file).
class SnapWindow {
  final Rect rect;
  final String title;
  final String app;
  // The CGWindowID (kCGWindowNumber), used to request a native per-window
  // capture (real alpha / rounded corners). Null when the native side didn't
  // emit it -> callers fall back to a rectangular crop.
  final int? windowId;
  const SnapWindow({
    required this.rect,
    required this.title,
    required this.app,
    this.windowId,
  });

  /// Best human label: the window title, or the app name when the title is
  /// unavailable (kCGWindowName can be empty even with Screen-Recording access).
  String get label => title.isNotEmpty ? title : app;
}

/// The frontmost focused window, as resolved natively (display-local logical
/// rect on [displayId], top-left origin). Lives here (next to [SnapWindow]) so
/// `capture_bridge.dart` — which already imports this file — can return it
/// without importing `direct_capture.dart` (which would create a cycle).
class FocusedWindowInfo {
  const FocusedWindowInfo({
    required this.displayId,
    required this.rect,
    required this.title,
    required this.app,
    this.windowId,
  });
  final int displayId;
  final Rect rect;
  final String title;
  final String app;
  // CGWindowID (kCGWindowNumber) for a native per-window capture; null -> the
  // direct "Capture Window" path falls back to a display capture.
  final int? windowId;

  factory FocusedWindowInfo.fromMap(Map<dynamic, dynamic> m) => FocusedWindowInfo(
        displayId: (m['displayId'] as num).toInt(),
        rect: Rect.fromLTWH((m['x'] as num).toDouble(), (m['y'] as num).toDouble(),
            (m['w'] as num).toDouble(), (m['h'] as num).toDouble()),
        title: (m['title'] as String?) ?? '',
        app: (m['app'] as String?) ?? '',
        windowId: (m['windowNumber'] as num?)?.toInt(),
      );
}

/// A single window captured natively WITH its real alpha (rounded corners
/// transparent outside the window shape). [pngBytes] are NATIVE-resolution;
/// [scale] maps native px -> logical points.
class WindowImage {
  const WindowImage({
    required this.pngBytes,
    required this.width,
    required this.height,
    required this.scale,
  });
  final Uint8List pngBytes;
  final int width;
  final int height;
  final double scale;

  factory WindowImage.fromMap(Map<dynamic, dynamic> m) => WindowImage(
        pngBytes: m['pngBytes'] as Uint8List,
        width: (m['width'] as num).toInt(),
        height: (m['height'] as num).toInt(),
        scale: (m['scale'] as num).toDouble(),
      );
}

/// One frozen display returned by the native capture channel.
/// [left/top/width/height] are LOGICAL global-desktop coords; [rawBytes] is
/// NATIVE-resolution BGRA8888 (premultiplied, sRGB) — raw pixels, no codec on
/// the freeze path; decode with `ui.decodeImageFromPixels`.
class CapturedDisplay {
  final int displayId;
  final Uint8List rawBytes;
  final int pixelWidth;
  final int pixelHeight;
  final int rowBytes;
  final double left;
  final double top;
  final double width;
  final double height;
  final double scaleFactor;
  final bool isCursorDisplay;
  // Cursor's display-local logical position at capture (top-left origin), only on
  // the cursor display — used to seed the crosshair where the pointer actually
  // is, instead of the display centre. Null on the non-cursor displays.
  final double? cursorX;
  final double? cursorY;
  // Snappable top-level windows on THIS display at capture time, display-local
  // logical (top-left origin), front-to-back z-order. Empty if none.
  final List<SnapWindow> windows;
  // The OS mouse pointer image (native px PNG, with alpha) + its display-local
  // LOGICAL top-left, captured for the OVERLAY's toggleable cursor layer. Only on
  // the cursor display, and only when the current cursor is a system cursor.
  final Uint8List? cursorImageBytes;
  final double? cursorLeft;
  final double? cursorTop;

  const CapturedDisplay({
    required this.displayId,
    required this.rawBytes,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.rowBytes,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.scaleFactor,
    required this.isCursorDisplay,
    this.cursorX,
    this.cursorY,
    this.windows = const [],
    this.cursorImageBytes,
    this.cursorLeft,
    this.cursorTop,
  });

  factory CapturedDisplay.fromMap(Map<dynamic, dynamic> m) => CapturedDisplay(
    displayId: m['displayId'] as int,
    rawBytes: m['rawBytes'] as Uint8List,
    pixelWidth: (m['pixelWidth'] as num).toInt(),
    pixelHeight: (m['pixelHeight'] as num).toInt(),
    rowBytes: (m['rowBytes'] as num).toInt(),
    left: (m['left'] as num).toDouble(),
    top: (m['top'] as num).toDouble(),
    width: (m['width'] as num).toDouble(),
    height: (m['height'] as num).toDouble(),
    scaleFactor: (m['scaleFactor'] as num).toDouble(),
    isCursorDisplay: m['isCursorDisplay'] as bool,
    cursorX: (m['cursorX'] as num?)?.toDouble(),
    cursorY: (m['cursorY'] as num?)?.toDouble(),
    cursorImageBytes: m['cursorImage'] as Uint8List?,
    cursorLeft: (m['cursorLeft'] as num?)?.toDouble(),
    cursorTop: (m['cursorTop'] as num?)?.toDouble(),
    windows: ((m['windows'] as List<dynamic>?) ?? const [])
        .map((e) => (e as Map).cast<dynamic, dynamic>())
        .map((w) => SnapWindow(
              rect: Rect.fromLTWH(
                (w['x'] as num).toDouble(),
                (w['y'] as num).toDouble(),
                (w['w'] as num).toDouble(),
                (w['h'] as num).toDouble(),
              ),
              title: (w['title'] as String?) ?? '',
              app: (w['app'] as String?) ?? '',
              windowId: (w['windowNumber'] as num?)?.toInt(),
            ))
        .toList(growable: false),
  );
}
