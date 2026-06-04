import 'package:flutter/widgets.dart';
import 'draw_style.dart';
import 'drawable.dart';

/// Explicit line height shared by the inline editor and the painter so the
/// committed text is pixel-identical to what was typed (WYSIWYG).
const double kTextLineHeight = 1.3;

/// Text style for a [DrawStyle] (colour + size + font family).
TextStyle textStyleOf(DrawStyle s) => TextStyle(
      color: s.color,
      fontSize: s.fontSize,
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
