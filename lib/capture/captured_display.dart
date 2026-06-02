import 'dart:typed_data';
import 'dart:ui' show Rect;

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
  // logical rects (top-left origin), front-to-back z-order. Empty if none.
  final List<Rect> windows;

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
        .map((e) => (e as List).cast<num>())
        .map((v) => Rect.fromLTWH(
            v[0].toDouble(), v[1].toDouble(), v[2].toDouble(), v[3].toDouble()))
        .toList(growable: false),
  );
}
