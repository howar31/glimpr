import 'dart:ui';

/// Color swatches shown in the options row (custom picker is Phase 4).
const List<Color> kColorPresets = [
  Color(0xFFFF3B30), // red
  Color(0xFFFF9500), // orange
  Color(0xFFFFCC00), // yellow
  Color(0xFF34C759), // green
  Color(0xFF007AFF), // blue
  Color(0xFF000000), // black
  Color(0xFFFFFFFF), // white
];

/// Stroke width presets (thin / medium / thick).
const List<double> kStrokeWidths = [2, 4, 8];

/// Immutable style shared by all drawables.
class DrawStyle {
  final Color color;
  final double strokeWidth;
  final double fontSize;
  const DrawStyle({
    this.color = const Color(0xFFFF3B30),
    this.strokeWidth = 3,
    this.fontSize = 18,
  });

  DrawStyle copyWith({Color? color, double? strokeWidth, double? fontSize}) =>
      DrawStyle(
        color: color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        fontSize: fontSize ?? this.fontSize,
      );

  @override
  bool operator ==(Object other) =>
      other is DrawStyle &&
      other.color == color &&
      other.strokeWidth == strokeWidth &&
      other.fontSize == fontSize;
  @override
  int get hashCode => Object.hash(color, strokeWidth, fontSize);
}
