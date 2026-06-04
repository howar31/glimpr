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

/// Continuous stroke-width slider bounds. The three quick presets
/// (kStrokeWidths) live inside this range.
const double kStrokeMin = 1;
const double kStrokeMax = 40;

/// Immutable style shared by all drawables.
class DrawStyle {
  final Color color;
  final double strokeWidth;
  final double fontSize;
  final String? fontFamily; // null = system default
  const DrawStyle({
    this.color = const Color(0xFFFF3B30),
    this.strokeWidth = 4, // matches the medium preset (kStrokeWidths[1])
    this.fontSize = 18,
    this.fontFamily,
  });

  DrawStyle copyWith({
    Color? color,
    double? strokeWidth,
    double? fontSize,
    String? fontFamily,
  }) => DrawStyle(
        color: color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        fontSize: fontSize ?? this.fontSize,
        fontFamily: fontFamily ?? this.fontFamily,
      );

  Map<String, dynamic> toJson() => {
        'color': color.toARGB32(),
        'strokeWidth': strokeWidth,
        'fontSize': fontSize,
        if (fontFamily != null) 'fontFamily': fontFamily,
      };

  factory DrawStyle.fromJson(Map<String, dynamic> j) => DrawStyle(
        color: Color((j['color'] as num?)?.toInt() ?? 0xFFFF3B30),
        strokeWidth: (j['strokeWidth'] as num?)?.toDouble() ?? 4,
        fontSize: (j['fontSize'] as num?)?.toDouble() ?? 18,
        fontFamily: j['fontFamily'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is DrawStyle &&
      other.color == color &&
      other.strokeWidth == strokeWidth &&
      other.fontSize == fontSize &&
      other.fontFamily == fontFamily;
  @override
  int get hashCode => Object.hash(color, strokeWidth, fontSize, fontFamily);
}
