import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/document.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/editor_controller.dart';

RectangleDrawable _rect() =>
    RectangleDrawable(const Rect.fromLTWH(0, 0, 10, 10), const DrawStyle());

void main() {
  group('EditorDocument history depth', () {
    test('grows by one per commit; silent replace keeps it', () {
      var doc = const EditorDocument();
      expect(doc.historyDepth, 1);
      doc = doc.add(_rect());
      expect(doc.historyDepth, 2);
      doc = doc.replaceAtSilent(0, _rect());
      expect(doc.historyDepth, 2);
      doc = doc.undo();
      expect(doc.historyDepth, 1);
      expect(doc.redoDepth, 1);
    });

    test('clearedRedo drops the redo tail only', () {
      var doc = const EditorDocument().add(_rect()).add(_rect());
      doc = doc.undo();
      expect(doc.canRedo, isTrue);
      final cleared = doc.clearedRedo();
      expect(cleared.canRedo, isFalse);
      expect(cleared.historyDepth, doc.historyDepth);
      expect(cleared.drawables, doc.drawables);
      // No-op (same instance) when there is nothing to clear.
      expect(identical(cleared.clearedRedo(), cleared), isTrue);
    });
  });

  group('EditorController undo/redo seam', () {
    test('undo()/redo() act locally when no override is set', () {
      final c = EditorController(toolStyles: {});
      c.document.value = c.document.value.add(_rect());
      c.undo();
      expect(c.document.value.drawables, isEmpty);
      c.redo();
      expect(c.document.value.drawables, hasLength(1));
      c.dispose();
    });

    test('overrides intercept undo()/redo(); locals still bypass', () {
      final c = EditorController(toolStyles: {});
      c.document.value = c.document.value.add(_rect());
      final calls = <String>[];
      c.undoOverride = () => calls.add('undo');
      c.redoOverride = () => calls.add('redo');
      c.undo();
      c.redo();
      // Routed to the session log, the local document untouched.
      expect(calls, ['undo', 'redo']);
      expect(c.document.value.drawables, hasLength(1));
      c.undoLocal();
      expect(c.document.value.drawables, isEmpty);
      c.redoLocal();
      expect(c.document.value.drawables, hasLength(1));
      c.dispose();
    });
  });
}
