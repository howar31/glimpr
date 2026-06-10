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

/// Stroke dash style for the line tools (line / arrow / highlighter). Patterns
/// scale with stroke width (see drawable_painter's dash runs). Other tools carry
/// the field but ignore it (like [HighlighterTexture]).
enum LineStyle { solid, dashed, dotted, longDash, dashDot, dashDotDot }

LineStyle _lineStyleFromName(Object? name) {
  for (final s in LineStyle.values) {
    if (s.name == name) return s;
  }
  return LineStyle.solid;
}

/// Which ends of an arrow carry a head (arrow tool only).
enum ArrowHeads { end, start, both }

ArrowHeads _arrowHeadsFromName(Object? name) {
  for (final h in ArrowHeads.values) {
    if (h.name == name) return h;
  }
  return ArrowHeads.end;
}

/// Interior control-point count for new line-tool shapes. 0 = a plain straight
/// two-endpoint line (the default); 1 = a single midpoint (C-curve); up to
/// [kCurvePointsMax] for S / multi-bend curves.
const int kCurvePointsMin = 0;
const int kCurvePointsMax = 5;
const int kCurvePointsDefault = 0;

/// Raster-effect strength (blur radius / pixelate block size), in PIXELS. Per
/// region; only the Blur/Pixelate tools read it (other tools carry but ignore it,
/// like [HighlighterTexture]). The default 12 reproduces the pre-strength look
/// exactly: blur reads it as LOGICAL px (native sigma = strength * pixelScale),
/// pixelate reads it as NATIVE block px. Clamped to [kRasterStrengthMin,
/// kRasterStrengthMax]; the option bar narrows the live range per tool.
const double kRasterStrengthDefault = 12;
const double kRasterStrengthMin = 2;
const double kRasterStrengthMax = 64;

/// Rectangle corner-radius sentinels. [kCornerRadiusAuto] (-1) reproduces the
/// legacy auto radius ((shortestSide/4).clamp(0,12)) — the default, so the export
/// stays byte-identical. >= 0 is an explicit radius. [kCornerRadiusMax] is the
/// option-bar stepper ceiling (the painter re-clamps to shortestSide/2);
/// [kCornerRadiusBaseline] is the value the stepper jumps to when leaving Auto.
const double kCornerRadiusAuto = -1;
const double kCornerRadiusMax = 80;
const double kCornerRadiusBaseline = 12;

/// Resolve the effective corner radius for [rect]. The auto sentinel maps to the
/// legacy auto radius; an explicit value clamps to [0, shortestSide/2] (the
/// geometric max before the rectangle becomes a stadium). Pure so it is unit
/// testable — the painter itself cannot be headless-rasterized.
double resolveCornerRadius(double cornerRadius, Rect rect) => cornerRadius < 0
    ? (rect.shortestSide / 4).clamp(0.0, 12.0)
    : cornerRadius.clamp(0.0, rect.shortestSide / 2);

/// Arrowhead size multiplier (arrow tool only). 1.0 = the legacy head size
/// (headLen = strokeWidth * 4.9), so the default keeps the export byte-identical;
/// the head still scales with stroke width, this just multiplies on top.
const double kArrowHeadScaleDefault = 1.0;
const double kArrowHeadScaleMin = 0.5;
const double kArrowHeadScaleMax = 3.0;

/// Step-badge numbering floor + shape (step tool only). [kStepStartDefault] = 1
/// reproduces the legacy auto-from-1 numbering; [StepShape.circle] is the legacy
/// shape — so the defaults keep the export byte-identical.
const int kStepStartDefault = 1;
const int kStepStartMin = 1;
const int kStepStartMax = 999;

/// Step badge outline shape.
enum StepShape { circle, square }

StepShape _stepShapeFromName(Object? name) {
  for (final s in StepShape.values) {
    if (s.name == name) return s;
  }
  return StepShape.circle;
}

/// Magnify-callout factor + connector (magnify tool only; other tools carry but
/// ignore these). The inset size = source × factor. The magnify lens is always a
/// right-angle rectangle — its corner-to-corner connector lines require square
/// corners to meet exactly — so there is no shape/rounding option.
const double kMagnifyFactorDefault = 2.0;
const double kMagnifyFactorMin = 1.5;
const double kMagnifyFactorMax = 6.0;

/// Immutable style shared by all drawables.
class DrawStyle {
  final Color color;
  final double strokeWidth;
  final double fontSize;
  final String? fontFamily; // null = system default
  final HighlighterTexture texture; // highlighter-only; ignored by other tools
  final bool shadow; // drop shadow under the annotation (drawing tools + text/step)
  final LineStyle lineStyle; // line tools only (solid/dashed/...); else ignored
  final ArrowHeads arrowHeads; // arrow only; which ends carry a head
  final int curvePoints; // interior control points seeded for new line shapes
  final double strength; // blur radius / pixelate block size; Blur/Pixelate only
  final Color fillColor; // rect/ellipse solid fill (own alpha); 0 alpha = no fill
  final double cornerRadius; // rectangle corner radius; kCornerRadiusAuto = legacy
  final Color outlineColor; // text glyph outline (own alpha); 0 alpha = no outline
  final double arrowHeadScale; // arrow head size multiplier; 1.0 = legacy size
  final int stepStart; // step badge numbering floor; 1 = legacy auto-from-1
  final StepShape stepShape; // step badge outline shape; circle = legacy
  final double magnifyFactor; // magnify inset zoom; inset = source * factor
  final bool magnifyConnector; // draw the source->inset connector lines
  const DrawStyle({
    this.color = const Color(0xFFFF3B30),
    this.strokeWidth = 4, // matches the medium preset (kStrokeWidths[1])
    this.fontSize = 18,
    this.fontFamily,
    this.texture = HighlighterTexture.streaks,
    this.shadow = false,
    this.lineStyle = LineStyle.solid,
    this.arrowHeads = ArrowHeads.end,
    this.curvePoints = kCurvePointsDefault,
    this.strength = kRasterStrengthDefault,
    this.fillColor = const Color(0x00000000),
    this.cornerRadius = kCornerRadiusAuto,
    this.outlineColor = const Color(0x00000000),
    this.arrowHeadScale = kArrowHeadScaleDefault,
    this.stepStart = kStepStartDefault,
    this.stepShape = StepShape.circle,
    this.magnifyFactor = kMagnifyFactorDefault,
    this.magnifyConnector = true,
  });

  DrawStyle copyWith({
    Color? color,
    double? strokeWidth,
    double? fontSize,
    String? fontFamily,
    HighlighterTexture? texture,
    bool? shadow,
    LineStyle? lineStyle,
    ArrowHeads? arrowHeads,
    int? curvePoints,
    double? strength,
    Color? fillColor,
    double? cornerRadius,
    Color? outlineColor,
    double? arrowHeadScale,
    int? stepStart,
    StepShape? stepShape,
    double? magnifyFactor,
    bool? magnifyConnector,
  }) => DrawStyle(
    color: color ?? this.color,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    fontSize: fontSize ?? this.fontSize,
    fontFamily: fontFamily ?? this.fontFamily,
    texture: texture ?? this.texture,
    shadow: shadow ?? this.shadow,
    lineStyle: lineStyle ?? this.lineStyle,
    arrowHeads: arrowHeads ?? this.arrowHeads,
    curvePoints: curvePoints ?? this.curvePoints,
    strength: strength ?? this.strength,
    fillColor: fillColor ?? this.fillColor,
    cornerRadius: cornerRadius ?? this.cornerRadius,
    outlineColor: outlineColor ?? this.outlineColor,
    arrowHeadScale: arrowHeadScale ?? this.arrowHeadScale,
    stepStart: stepStart ?? this.stepStart,
    stepShape: stepShape ?? this.stepShape,
    magnifyFactor: magnifyFactor ?? this.magnifyFactor,
    magnifyConnector: magnifyConnector ?? this.magnifyConnector,
  );

  Map<String, dynamic> toJson() => {
    'color': color.toARGB32(),
    'strokeWidth': strokeWidth,
    'fontSize': fontSize,
    if (fontFamily != null) 'fontFamily': fontFamily,
    'texture': texture.name,
    if (shadow) 'shadow': true,
    if (lineStyle != LineStyle.solid) 'lineStyle': lineStyle.name,
    if (arrowHeads != ArrowHeads.end) 'arrowHeads': arrowHeads.name,
    if (curvePoints != kCurvePointsDefault) 'curvePoints': curvePoints,
    if (strength != kRasterStrengthDefault) 'strength': strength,
    if (fillColor.a != 0) 'fillColor': fillColor.toARGB32(),
    if (cornerRadius != kCornerRadiusAuto) 'cornerRadius': cornerRadius,
    if (outlineColor.a != 0) 'outlineColor': outlineColor.toARGB32(),
    if (arrowHeadScale != kArrowHeadScaleDefault) 'arrowHeadScale': arrowHeadScale,
    if (stepStart != kStepStartDefault) 'stepStart': stepStart,
    if (stepShape != StepShape.circle) 'stepShape': stepShape.name,
    if (magnifyFactor != kMagnifyFactorDefault) 'magnifyFactor': magnifyFactor,
    if (!magnifyConnector) 'magnifyConnector': false,
  };

  factory DrawStyle.fromJson(Map<String, dynamic> j) => DrawStyle(
    color: Color((j['color'] as num?)?.toInt() ?? 0xFFFF3B30),
    strokeWidth: (j['strokeWidth'] as num?)?.toDouble() ?? 4,
    fontSize: (j['fontSize'] as num?)?.toDouble() ?? 18,
    fontFamily: j['fontFamily'] as String?,
    texture: _textureFromName(j['texture']),
    shadow: j['shadow'] as bool? ?? false,
    lineStyle: _lineStyleFromName(j['lineStyle']),
    arrowHeads: _arrowHeadsFromName(j['arrowHeads']),
    curvePoints: ((j['curvePoints'] as num?)?.toInt() ?? kCurvePointsDefault)
        .clamp(kCurvePointsMin, kCurvePointsMax),
    strength: ((j['strength'] as num?)?.toDouble() ?? kRasterStrengthDefault)
        .clamp(kRasterStrengthMin, kRasterStrengthMax),
    fillColor: Color((j['fillColor'] as num?)?.toInt() ?? 0x00000000),
    cornerRadius: (j['cornerRadius'] as num?)?.toDouble() ?? kCornerRadiusAuto,
    outlineColor: Color((j['outlineColor'] as num?)?.toInt() ?? 0x00000000),
    arrowHeadScale:
        ((j['arrowHeadScale'] as num?)?.toDouble() ?? kArrowHeadScaleDefault)
            .clamp(kArrowHeadScaleMin, kArrowHeadScaleMax),
    stepStart: ((j['stepStart'] as num?)?.toInt() ?? kStepStartDefault)
        .clamp(kStepStartMin, kStepStartMax),
    stepShape: _stepShapeFromName(j['stepShape']),
    magnifyFactor: ((j['magnifyFactor'] as num?)?.toDouble() ?? kMagnifyFactorDefault)
        .clamp(kMagnifyFactorMin, kMagnifyFactorMax),
    magnifyConnector: j['magnifyConnector'] as bool? ?? true,
  );

  @override
  bool operator ==(Object other) =>
      other is DrawStyle &&
      other.color == color &&
      other.strokeWidth == strokeWidth &&
      other.fontSize == fontSize &&
      other.fontFamily == fontFamily &&
      other.texture == texture &&
      other.shadow == shadow &&
      other.lineStyle == lineStyle &&
      other.arrowHeads == arrowHeads &&
      other.curvePoints == curvePoints &&
      other.strength == strength &&
      other.fillColor == fillColor &&
      other.cornerRadius == cornerRadius &&
      other.outlineColor == outlineColor &&
      other.arrowHeadScale == arrowHeadScale &&
      other.stepStart == stepStart &&
      other.stepShape == stepShape &&
      other.magnifyFactor == magnifyFactor &&
      other.magnifyConnector == magnifyConnector;
  @override
  int get hashCode => Object.hash(color, strokeWidth, fontSize, fontFamily,
      texture, shadow, lineStyle, arrowHeads, curvePoints, strength, fillColor,
      cornerRadius, outlineColor, arrowHeadScale, stepStart, stepShape,
      magnifyFactor, magnifyConnector);
}
