import 'dart:math' as math;
import 'dart:ui' as ui;

/// Logical-px appearance constants (multiplied by the display scale factor in
/// [DecorationStyle.scaled]). Owner-tuned on-device — same model as the arrow /
/// drop-shadow tunables.
const double kDecorMarginLogical = 60; // breathing room each side
const double kDecorCornerRadiusLogical = 12; // content corner radius
const double kDecorShadowBlurLogical = 14; // gaussian sigma
const ui.Offset kDecorShadowOffsetLogical = ui.Offset(0, 6); // downward
const ui.Color kDecorShadowColor = ui.Color(0x59000000); // black ~35%

/// Visual parameters for the opt-in capture decoration (margin + rounded corners
/// + drop shadow). All lengths are in the SAME pixel space as the image passed to
/// [applyDecoration] (native pixels for a capture). Build the per-capture instance
/// via [DecorationStyle.scaled].
class DecorationStyle {
  const DecorationStyle({
    required this.margin,
    required this.cornerRadius,
    required this.shadowBlur,
    required this.shadowOffset,
    this.shadowColor = kDecorShadowColor,
  });

  /// The shared appearance scaled from logical constants to native pixels.
  factory DecorationStyle.scaled(double scale) => DecorationStyle(
    margin: kDecorMarginLogical * scale,
    cornerRadius: kDecorCornerRadiusLogical * scale,
    shadowBlur: kDecorShadowBlurLogical * scale,
    shadowOffset: kDecorShadowOffsetLogical * scale,
  );

  final double margin;
  final double cornerRadius;
  final double shadowBlur;
  final ui.Offset shadowOffset;
  final ui.Color shadowColor;

  /// Never smaller than the shadow's reach, so the shadow can't be clipped by the
  /// output bounds.
  double get effectiveMargin => math.max(
    margin,
    shadowBlur + math.max(shadowOffset.dx.abs(), shadowOffset.dy.abs()),
  );

  /// The native CG decorator's `decoration` sub-map carrying THESE (already
  /// scaled) appearance values; the native side multiplies by `scale` (pass
  /// 1.0 since the values are native-px). [fillArgb] non-null fills the margin
  /// (JPEG); null keeps it transparent (PNG).
  Map<String, dynamic> toNativeSpec({
    int? fillArgb,
    required bool shapeFromAlpha,
  }) =>
      decorationSpecMap(
        margin: margin,
        cornerRadius: cornerRadius,
        shadowBlur: shadowBlur,
        shadowOffset: shadowOffset,
        shadowColorArgb: shadowColor.toARGB32(),
        fillArgb: fillArgb,
        shapeFromAlpha: shapeFromAlpha,
      );
}

/// Build the `decoration` channel sub-map for the native CG decorator
/// (`glimpr/encode` decorate / captureRegion). Lengths are passed verbatim and
/// multiplied by the native `scale`: pass logical constants with the display
/// scale, or already-scaled values with scale 1.
Map<String, dynamic> decorationSpecMap({
  required double margin,
  required double cornerRadius,
  required double shadowBlur,
  required ui.Offset shadowOffset,
  required int shadowColorArgb,
  int? fillArgb,
  required bool shapeFromAlpha,
}) =>
    {
      'margin': margin,
      'cornerRadius': cornerRadius,
      'shadowBlur': shadowBlur,
      'shadowDx': shadowOffset.dx,
      'shadowDy': shadowOffset.dy,
      'shadowColor': shadowColorArgb,
      'fill': ?fillArgb,
      'shapeFromAlpha': shapeFromAlpha,
    };

/// The shared LOGICAL decoration spec (the kDecor* constants) for the native
/// direct-capture path, where Dart does not yet know the display scale — native
/// multiplies these by the captured display's scale. Mirrors
/// [DecorationStyle.scaled]'s source constants so both paths look identical.
Map<String, dynamic> logicalDecorationSpec({
  int? fillArgb,
  required bool shapeFromAlpha,
}) =>
    decorationSpecMap(
      margin: kDecorMarginLogical,
      cornerRadius: kDecorCornerRadiusLogical,
      shadowBlur: kDecorShadowBlurLogical,
      shadowOffset: kDecorShadowOffsetLogical,
      shadowColorArgb: kDecorShadowColor.toARGB32(),
      fillArgb: fillArgb,
      shapeFromAlpha: shapeFromAlpha,
    );

/// Wrap [content] in [style]'s margin + rounded corners + drop shadow, returning
/// a NEW, larger image. When [fill] is non-null (JPEG output) the whole canvas is
/// painted with it first (no transparency); when null (PNG) the margin and corner
/// gaps stay transparent. The caller disposes [content] and the returned image.
Future<ui.Image> applyDecoration(
  ui.Image content,
  DecorationStyle style, {
  ui.Color? fill,
  bool shapeFromContentAlpha = false,
}) async {
  final m = style.effectiveMargin;
  final cw = content.width.toDouble();
  final ch = content.height.toDouble();
  final outW = (cw + 2 * m).round();
  final outH = (ch + 2 * m).round();

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  if (fill != null) {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
      ui.Paint()..color = fill,
    );
  }

  if (shapeFromContentAlpha) {
    // The content already carries its REAL shape (a window's alpha). Draw the
    // drop shadow from the content's OWN silhouette (tint to the shadow colour +
    // blur), then the content on top — NO rounded-rect clip (the alpha is truth).
    if (style.shadowBlur > 0 || style.shadowColor.a > 0) {
      final shadowPaint = ui.Paint()
        ..colorFilter = ui.ColorFilter.mode(
          style.shadowColor,
          ui.BlendMode.srcIn,
        );
      if (style.shadowBlur > 0) {
        shadowPaint.maskFilter = ui.MaskFilter.blur(
          ui.BlurStyle.normal,
          style.shadowBlur,
        );
      }
      canvas.drawImage(content, ui.Offset(m, m) + style.shadowOffset, shadowPaint);
    }
    canvas.drawImage(content, ui.Offset(m, m), ui.Paint());
  } else {
    final contentRect = ui.Rect.fromLTWH(m, m, cw, ch);
    final rrect = ui.RRect.fromRectAndRadius(
      contentRect,
      ui.Radius.circular(style.cornerRadius),
    );

    // Drop shadow: a blurred fill of the rounded rect, offset behind the content.
    if (style.shadowBlur > 0 || style.shadowColor.a > 0) {
      final paint = ui.Paint()..color = style.shadowColor;
      if (style.shadowBlur > 0) {
        paint.maskFilter = ui.MaskFilter.blur(
          ui.BlurStyle.normal,
          style.shadowBlur,
        );
      }
      canvas.drawRRect(rrect.shift(style.shadowOffset), paint);
    }

    // Content, corners rounded (also clips a snapped window's corner-gap pixels).
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawImage(content, ui.Offset(m, m), ui.Paint());
    canvas.restore();
  }

  final picture = recorder.endRecording();
  final img = await picture.toImage(outW, outH);
  picture.dispose();
  return img;
}
