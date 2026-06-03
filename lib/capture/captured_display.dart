import 'dart:typed_data';
import 'dart:ui' show Rect;

/// A snappable top-level window at capture time: its display-local logical [rect]
/// plus the window [title] and owning [app] name (for naming the saved file).
class SnapWindow {
  final Rect rect;
  final String title;
  final String app;
  const SnapWindow({required this.rect, required this.title, required this.app});

  /// Best human label: the window title, or the app name when the title is
  /// unavailable (kCGWindowName can be empty even with Screen-Recording access).
  String get label => title.isNotEmpty ? title : app;
}

/// One frozen display returned by the native capture channel.
/// [left/top/width/height] are LOGICAL global-desktop coords; [pngBytes] is NATIVE resolution.
class CapturedDisplay {
  final int displayId;
  final Uint8List pngBytes;
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

  const CapturedDisplay({
    required this.displayId,
    required this.pngBytes,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.scaleFactor,
    required this.isCursorDisplay,
    this.cursorX,
    this.cursorY,
    this.windows = const [],
  });

  factory CapturedDisplay.fromMap(Map<dynamic, dynamic> m) => CapturedDisplay(
    displayId: m['displayId'] as int,
    pngBytes: m['pngBytes'] as Uint8List,
    left: (m['left'] as num).toDouble(),
    top: (m['top'] as num).toDouble(),
    width: (m['width'] as num).toDouble(),
    height: (m['height'] as num).toDouble(),
    scaleFactor: (m['scaleFactor'] as num).toDouble(),
    isCursorDisplay: m['isCursorDisplay'] as bool,
    cursorX: (m['cursorX'] as num?)?.toDouble(),
    cursorY: (m['cursorY'] as num?)?.toDouble(),
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
            ))
        .toList(growable: false),
  );
}
