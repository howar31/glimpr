import 'package:flutter/widgets.dart';
import '../editor/drawable.dart';
import '../editor/text_metrics.dart';

class _CharStyle {
  final Color color;
  final double size;
  const _CharStyle(this.color, this.size);
  @override
  bool operator ==(Object o) =>
      o is _CharStyle && o.color == color && o.size == size;
  @override
  int get hashCode => Object.hash(color, size);
}

/// A TextEditingController that carries a per-character style (color + size), so
/// one text field can hold mixed styles. The field renders the glyphs
/// TRANSPARENT (the canvas painter draws the visible rich text) but at the real
/// per-run sizes, so the caret/selection layout matches what is painted.
class RichTextController extends TextEditingController {
  List<_CharStyle> _styles;
  _CharStyle _current; // style applied to newly typed characters

  RichTextController({
    String text = '',
    required Color color,
    required double size,
  }) : _current = _CharStyle(color, size),
       _styles = List.filled(
         text.length,
         _CharStyle(color, size),
         growable: true,
       ),
       super(text: text);

  factory RichTextController.fromRuns(
    List<TextRun> runs, {
    required Color color,
    required double size,
  }) {
    final buffer = StringBuffer();
    final styles = <_CharStyle>[];
    for (final r in runs) {
      buffer.write(r.text);
      for (var i = 0; i < r.text.length; i++) {
        styles.add(_CharStyle(r.color, r.fontSize));
      }
    }
    return RichTextController(text: buffer.toString(), color: color, size: size)
      .._styles = styles;
  }

  @override
  set value(TextEditingValue newValue) {
    if (newValue.text != text) _reconcile(text, newValue.text);
    super.value = newValue;
  }

  /// Keep [_styles] aligned with the text across an edit by diffing the common
  /// prefix/suffix and re-styling only the changed middle with [_current].
  void _reconcile(String oldT, String newT) {
    final minLen = oldT.length < newT.length ? oldT.length : newT.length;
    var p = 0;
    while (p < minLen && oldT.codeUnitAt(p) == newT.codeUnitAt(p)) {
      p++;
    }
    var s = 0;
    while (s < minLen - p &&
        oldT.codeUnitAt(oldT.length - 1 - s) ==
            newT.codeUnitAt(newT.length - 1 - s)) {
      s++;
    }
    final removeCount = oldT.length - s - p;
    final insertCount = newT.length - s - p;
    final next = [..._styles];
    if (removeCount > 0) next.removeRange(p, p + removeCount);
    if (insertCount > 0) next.insertAll(p, List.filled(insertCount, _current));
    _styles = next;
  }

  void _ensure() {
    if (_styles.length == text.length) return;
    if (_styles.length < text.length) {
      _styles = [
        ..._styles,
        ...List.filled(text.length - _styles.length, _current),
      ];
    } else {
      _styles = _styles.sublist(0, text.length);
    }
  }

  /// Apply a style to the current selection; if the selection is collapsed, set
  /// the style for subsequent typing instead.
  void applyStyle(Color color, double size) {
    _ensure();
    _current = _CharStyle(color, size);
    final sel = selection;
    if (sel.isValid && !sel.isCollapsed) {
      for (var i = sel.start; i < sel.end && i < _styles.length; i++) {
        _styles[i] = _CharStyle(color, size);
      }
    }
    notifyListeners();
  }

  /// The styled runs (consecutive equal styles merged) for the painter + model.
  List<TextRun> toRuns() {
    _ensure();
    final runs = <TextRun>[];
    var i = 0;
    while (i < text.length) {
      var j = i;
      while (j < text.length && _styles[j] == _styles[i]) {
        j++;
      }
      runs.add(
        TextRun(text.substring(i, j), _styles[i].color, _styles[i].size),
      );
      i = j;
    }
    return runs;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    _ensure();
    final children = <InlineSpan>[];
    var i = 0;
    while (i < text.length) {
      var j = i;
      while (j < text.length && _styles[j] == _styles[i]) {
        j++;
      }
      children.add(
        TextSpan(
          text: text.substring(i, j),
          // Transparent glyphs (painter draws the visible text); REAL size so the
          // caret/selection geometry matches the painted result.
          style: TextStyle(
            color: const Color(0x00000000),
            fontSize: _styles[i].size,
            height: kTextLineHeight,
          ),
        ),
      );
      i = j;
    }
    return TextSpan(style: style, children: children);
  }
}
