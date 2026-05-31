import 'dart:ui' show Color;
import 'package:flutter/foundation.dart';
import 'draw_style.dart';
import 'drawable.dart';
import 'document.dart';

enum ToolKind { select, rectangle, arrow, text, crop }
enum EditorPhase { annotate, crop }

/// Mutable editor state exposed as ValueListenables so widgets rebuild narrowly.
class EditorController {
  final tool = ValueNotifier<ToolKind>(ToolKind.select);
  final style = ValueNotifier<DrawStyle>(const DrawStyle());
  final document = ValueNotifier<EditorDocument>(const EditorDocument());
  final selectedIndex = ValueNotifier<int?>(null);
  final phase = ValueNotifier<EditorPhase>(EditorPhase.annotate);

  void selectTool(ToolKind t) {
    tool.value = t;
    phase.value = t == ToolKind.crop ? EditorPhase.crop : EditorPhase.annotate;
    if (t != ToolKind.select) selectedIndex.value = null;
  }

  void setColor(Color c) => style.value = style.value.copyWith(color: c);
  void setStrokeWidth(double w) =>
      style.value = style.value.copyWith(strokeWidth: w);
  void setFontSize(double s) => style.value = style.value.copyWith(fontSize: s);

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
