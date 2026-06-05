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

/// Default highlighter colour (translucent yellow). MUST equal the first
/// [kHighlighterPresets] entry so the default sits inside the highlighter palette.
const Color kHighlighterDefaultColor = Color(0x66FFEB3B);

/// Translucent fluorescent quick-pick colours for the highlighter tool, shown
/// instead of [kColorPresets] when the highlighter is active. Each carries an
/// alpha so the marker reads as translucent ink (the painter honours it).
const List<Color> kHighlighterPresets = [
  kHighlighterDefaultColor, // yellow (the default)
  Color(0x6676FF03), // green
  Color(0x6600E5FF), // cyan
  Color(0x66FF4FD8), // pink
  Color(0x66FF9100), // orange
  Color(0x66B388FF), // purple
];

/// Stroke width presets (thin / medium / thick).
const List<double> kStrokeWidths = [2, 4, 8];

/// Continuous stroke-width slider bounds. The three quick presets
/// (kStrokeWidths) live inside this range.
const double kStrokeMin = 1;
const double kStrokeMax = 40;

/// Brush texture for the highlighter tool (consumed only by its painter). Other
/// tools carry the field but ignore it (it rides on the shared [DrawStyle], like
/// [DrawStyle.fontFamily] which only the Text tool uses).
enum HighlighterTexture { clean, streaks, frayed }

/// Parse a [HighlighterTexture] by name, falling back to [streaks] for a
/// missing/garbage value (forward/backward compatible persistence).
HighlighterTexture _textureFromName(Object? name) {
  for (final t in HighlighterTexture.values) {
    if (t.name == name) return t;
  }
  return HighlighterTexture.streaks;
}

/// Immutable style shared by all drawables.
class DrawStyle {
  final Color color;
  final double strokeWidth;
  final double fontSize;
  final String? fontFamily; // null = system default
  final HighlighterTexture texture; // highlighter-only; ignored by other tools
  final bool shadow; // drop shadow under the annotation (drawing tools + text/step)
  const DrawStyle({
    this.color = const Color(0xFFFF3B30),
    this.strokeWidth = 4, // matches the medium preset (kStrokeWidths[1])
    this.fontSize = 18,
    this.fontFamily,
    this.texture = HighlighterTexture.streaks,
    this.shadow = false,
  });

  DrawStyle copyWith({
    Color? color,
    double? strokeWidth,
    double? fontSize,
    String? fontFamily,
    HighlighterTexture? texture,
    bool? shadow,
  }) => DrawStyle(
    color: color ?? this.color,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    fontSize: fontSize ?? this.fontSize,
    fontFamily: fontFamily ?? this.fontFamily,
    texture: texture ?? this.texture,
    shadow: shadow ?? this.shadow,
  );

  Map<String, dynamic> toJson() => {
    'color': color.toARGB32(),
    'strokeWidth': strokeWidth,
    'fontSize': fontSize,
    if (fontFamily != null) 'fontFamily': fontFamily,
    'texture': texture.name,
    if (shadow) 'shadow': true,
  };

  factory DrawStyle.fromJson(Map<String, dynamic> j) => DrawStyle(
    color: Color((j['color'] as num?)?.toInt() ?? 0xFFFF3B30),
    strokeWidth: (j['strokeWidth'] as num?)?.toDouble() ?? 4,
    fontSize: (j['fontSize'] as num?)?.toDouble() ?? 18,
    fontFamily: j['fontFamily'] as String?,
    texture: _textureFromName(j['texture']),
    shadow: j['shadow'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is DrawStyle &&
      other.color == color &&
      other.strokeWidth == strokeWidth &&
      other.fontSize == fontSize &&
      other.fontFamily == fontFamily &&
      other.texture == texture &&
      other.shadow == shadow;
  @override
  int get hashCode =>
      Object.hash(color, strokeWidth, fontSize, fontFamily, texture, shadow);
}
