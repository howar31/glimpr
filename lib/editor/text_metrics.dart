import 'package:flutter/widgets.dart';
import 'drawable.dart';

/// Measures a TextDrawable's rendered size with a one-off TextPainter so the
/// model itself stays free of Flutter painting deps in its constructors.
Size measureText(TextDrawable d) {
  final tp = TextPainter(
    text: TextSpan(
      text: d.text.isEmpty ? ' ' : d.text,
      style: TextStyle(color: d.style.color, fontSize: d.style.fontSize),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  return tp.size;
}
