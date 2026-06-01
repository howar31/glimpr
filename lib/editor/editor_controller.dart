import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import 'draw_style.dart';
import 'drawable.dart';
import 'document.dart';

enum ToolKind {
  crop,
  rectangle,
  ellipse,
  arrow,
  line,
  pen,
  highlighter,
  text,
  step,
  blur,
  pixelate,
  paste,
}
enum EditorPhase { annotate, crop }

/// Mutable editor state exposed as ValueListenables so widgets rebuild narrowly.
/// Defaults to the Crop tool — most captures are a plain crop; annotation tools
/// are opt-in (Flow B: draw first if you want, then crop).
class EditorController {
  /// Last-used style per tool, remembered across tool switches (and, when the
  /// same map instance is reused, across captures). Owned externally so it
  /// survives the controller being recreated for a new capture.
  final Map<ToolKind, DrawStyle> toolStyles;

  final tool = ValueNotifier<ToolKind>(ToolKind.crop);
  final style = ValueNotifier<DrawStyle>(const DrawStyle());
  final document = ValueNotifier<EditorDocument>(const EditorDocument());
  final selectedIndex = ValueNotifier<int?>(null);
  final phase = ValueNotifier<EditorPhase>(EditorPhase.crop);

  EditorController({Map<ToolKind, DrawStyle>? toolStyles})
      : toolStyles = toolStyles ?? {} {
    // Seed the active style from any remembered tool so a fresh capture keeps
    // the user's last look instead of resetting to defaults.
    final seed = this.toolStyles[ToolKind.rectangle] ??
        this.toolStyles[ToolKind.arrow] ??
        this.toolStyles[ToolKind.text];
    if (seed != null) style.value = seed;
  }

  void selectTool(ToolKind t) {
    tool.value = t;
    phase.value = t == ToolKind.crop ? EditorPhase.crop : EditorPhase.annotate;
    selectedIndex.value = null; // switching tools drops the per-type selection
    if (t != ToolKind.crop) {
      final saved = toolStyles[t];
      if (saved != null) style.value = saved; // restore this tool's last style
    }
  }

  void setColor(Color c) => _updateStyle(style.value.copyWith(color: c));
  void setStrokeWidth(double w) =>
      _updateStyle(style.value.copyWith(strokeWidth: w));
  void setFontSize(double s) => _updateStyle(style.value.copyWith(fontSize: s));

  void _updateStyle(DrawStyle s) {
    style.value = s;
    if (tool.value != ToolKind.crop) toolStyles[tool.value] = s; // remember it
    _restyleSelected();
  }

  /// "Edit": when a drawable is selected (hovered/clicked), a style change also
  /// updates that drawable, not just the style for future ones.
  void _restyleSelected() {
    final i = selectedIndex.value;
    if (i == null || i >= document.value.drawables.length) return;
    final d = document.value.drawables[i];
    final Drawable restyled = switch (d) {
      RectangleDrawable() => d.withStyle(style.value),
      EllipseDrawable() => d.withStyle(style.value),
      ArrowDrawable() => d.withStyle(style.value),
      LineDrawable() => d.withStyle(style.value),
      HighlighterDrawable() => d.withStyle(style.value),
      PenDrawable() => d.withStyle(style.value),
      TextDrawable() => d.withStyle(style.value),
      StepDrawable() => d.withStyle(style.value),
      // Raster regions carry no editable style (no color/width in their options).
      BlurDrawable() => d,
      PixelateDrawable() => d,
      ImageDrawable() => d,
    };
    document.value = document.value.replaceAt(i, restyled);
  }

  void commitDrawable(Drawable d) =>
      document.value = document.value.add(d);

  void replaceSelected(Drawable d) {
    final i = selectedIndex.value;
    if (i != null) document.value = document.value.replaceAt(i, d);
  }

  void deleteSelected() {
    final i = selectedIndex.value;
    if (i != null) {
      document.value = document.value.removeAt(i);
      selectedIndex.value = null;
    }
  }

  void undo() => document.value = document.value.undo();
  void redo() => document.value = document.value.redo();

  void dispose() {
    tool.dispose();
    style.dispose();
    document.dispose();
    selectedIndex.dispose();
    phase.dispose();
  }
}
