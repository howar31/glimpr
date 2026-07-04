import 'package:flutter/widgets.dart';
import 'draw_style.dart';
import 'drawable.dart';

/// Explicit line height shared by the inline editor and the painter so the
/// committed text is pixel-identical to what was typed (WYSIWYG).
const double kTextLineHeight = 1.3;

/// Text style for a [DrawStyle] (colour + size + font family). [fontSizeCanvas]
/// converts the IMAGE-PIXEL size to canvas units (see draw_style.dart).
TextStyle textStyleOf(DrawStyle s) => TextStyle(
      color: s.color,
      fontSize: s.fontSizeCanvas,
      height: kTextLineHeight,
      fontFamily: s.fontFamily,
    );

/// Builds the TextSpan for a [TextDrawable] in its single style. Empty text
/// falls back to a single space so it still has a height. The inline editor
/// field uses the same style (transparent glyphs) so the painted text lays out
/// identically to the caret/selection geometry (WYSIWYG, zero shift on commit).
TextSpan buildTextSpan(TextDrawable d) =>
    TextSpan(text: d.text.isEmpty ? ' ' : d.text, style: textStyleOf(d.style));

/// Measures a TextDrawable's rendered size with a one-off TextPainter so the
/// model itself stays free of Flutter painting deps in its constructors.
Size measureText(TextDrawable d) {
  final tp = TextPainter(
    text: buildTextSpan(d),
    textDirection: TextDirection.ltr,
    strutStyle: StrutStyle.disabled, // match the inline field's layout
  )..layout();
  return tp.size;
}

// ---- text background pill + glyph outline geometry (A1) ----------------------
// All font-scaled and PURE (operate on an already-measured Rect, no TextPainter),
// so the painter and TextDrawable.bounds share one source of truth.

const double kTextBgPadXFactor = 0.35; // horizontal padding = fontSize * factor
const double kTextBgPadYFactor = 0.18; // vertical padding = fontSize * factor

double textBgPadX(double fontSize) => fontSize * kTextBgPadXFactor;
double textBgPadY(double fontSize) => fontSize * kTextBgPadYFactor;

/// The background pill rect: the measured text [textRect] padded out by the
/// font-scaled padding (so the text sits centred inside the pill).
Rect textBackgroundRect(Rect textRect, double fontSize) => Rect.fromLTRB(
      textRect.left - textBgPadX(fontSize),
      textRect.top - textBgPadY(fontSize),
      textRect.right + textBgPadX(fontSize),
      textRect.bottom + textBgPadY(fontSize),
    );

/// Pill corner radius — font-scaled, capped to half the short side (never a
/// degenerate over-round).
double textBackgroundRadius(Rect bgRect, double fontSize) =>
    (fontSize * 0.3).clamp(0.0, bgRect.shortestSide / 2);

/// Glyph outline stroke width — font-scaled, clamped to a legible range.
double textOutlineWidth(double fontSize) => (fontSize * 0.12).clamp(1.0, 10.0);
