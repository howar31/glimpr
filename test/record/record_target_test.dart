import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/record/record_target.dart';

void main() {
  const winRect = Rect.fromLTWH(10, 20, 300, 200);
  const win = SnapWindow(
      rect: winRect, title: 'Safari', app: 'Safari', windowId: 42);

  group('recordTargetFromSelection', () {
    test('a DRAG records its region even with a window under the cursor', () {
      // The screenshot onExport contract: window = window under the cursor
      // (names the file). The dragged rect differs from the window rect.
      const dragged = Rect.fromLTWH(50, 60, 120, 80);
      final t = recordTargetFromSelection(dragged, win);
      expect(t.rect, dragged);
      expect(t.windowId, isNull);
    });

    test('a SNAP click (selection == window rect) records the window', () {
      final t = recordTargetFromSelection(winRect, win);
      expect(t.windowId, 42);
      expect(t.rect, isNull);
    });

    test('a snap without a windowId degrades to its fixed rect', () {
      const anon =
          SnapWindow(rect: winRect, title: 'X', app: 'X', windowId: null);
      final t = recordTargetFromSelection(winRect, anon);
      expect(t.windowId, isNull);
      expect(t.rect, winRect);
    });

    test('no selection records the whole display', () {
      final t = recordTargetFromSelection(null, win);
      expect(t.rect, isNull);
      expect(t.windowId, isNull);
    });

    test('no selection and no window records the whole display too', () {
      final t = recordTargetFromSelection(null, null);
      expect(t.rect, isNull);
      expect(t.windowId, isNull);
    });
  });
}
