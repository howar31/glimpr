import 'package:flutter/widgets.dart';
import 'draw_style.dart';
import 'drawable.dart';

/// Explicit line height shared by the inline editor and the painter so the
/// committed text is pixel-identical to what was typed (WYSIWYG).
const double kTextLineHeight = 1.3;

/// Base text style for a single-style draw style (used as a fallback).
TextStyle textStyleOf(DrawStyle s) =>
    TextStyle(color: s.color, fontSize: s.fontSize, height: kTextLineHeight);

/// Builds the (possibly multi-style) TextSpan for a [TextDrawable] from its
/// runs. Empty text falls back to a single space so it still has a height.
TextSpan buildTextSpan(TextDrawable d) {
  if (d.runs.isEmpty || d.text.isEmpty) {
    return TextSpan(text: ' ', style: textStyleOf(d.style));
  }
  return TextSpan(
    children: [
      for (final r in d.runs)
        TextSpan(
          text: r.text,
          style: TextStyle(
            color: r.color,
            fontSize: r.fontSize,
            height: kTextLineHeight,
          ),
        ),
    ],
  );
}

/// Measures a TextDrawable's rendered size with a one-off TextPainter so the
/// model itself stays free of Flutter painting deps in its constructors.
Size measureText(TextDrawable d) {
  final tp = TextPainter(
    text: buildTextSpan(d),
    textDirection: TextDirection.ltr,
  )..layout();
  return tp.size;
}
