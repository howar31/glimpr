import 'dart:typed_data';

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

  const CapturedDisplay({
    required this.displayId,
    required this.pngBytes,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.scaleFactor,
    required this.isCursorDisplay,
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
      );
}
