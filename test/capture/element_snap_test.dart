import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/capture/element_snap.dart';
import 'package:glimpr/editor/editor_core.dart';

void main() {
  group('resolveSnapRect', () {
    final win = const SnapWindow(
        rect: Rect.fromLTWH(0, 0, 800, 600), title: 'W', app: 'A');
    const el = ElementSnap(
        rect: Rect.fromLTWH(10, 10, 100, 40),
        role: 'AXButton', title: 'OK', app: 'A', latencyUs: 0);

    test('prefers the element, falls back to the window, else null', () {
      expect(resolveSnapRect(element: el, window: win), el.rect);
      expect(resolveSnapRect(element: null, window: win), win.rect);
      expect(resolveSnapRect(element: null, window: null), isNull);
    });
  });

  group('ElementSnap.fromMap', () {
    test('parses rect / label / window / latency', () {
      final e = ElementSnap.fromMap({
        'x': 10.0, 'y': 20.0, 'w': 100.0, 'h': 40.0,
        'role': 'AXButton', 'title': 'OK', 'app': 'Safari',
        'windowId': 7,
        'winX': 0.0, 'winY': 0.0, 'winW': 800.0, 'winH': 600.0,
        'latencyUs': 1234,
      });
      expect(e.rect, const Rect.fromLTWH(10, 20, 100, 40));
      expect(e.label, 'OK');
      expect(e.windowId, 7);
      expect(e.winBounds, const Rect.fromLTWH(0, 0, 800, 600));
      expect(e.latencyUs, 1234);
    });

    test('label falls back to app then role; winBounds null when absent', () {
      final e = ElementSnap.fromMap(
          {'x': 0.0, 'y': 0.0, 'w': 1.0, 'h': 1.0, 'role': 'AXGroup', 'app': 'X'});
      expect(e.label, 'X');
      expect(e.winBounds, isNull);
      expect(e.windowId, isNull);

      final e2 = ElementSnap.fromMap(
          {'x': 0.0, 'y': 0.0, 'w': 1.0, 'h': 1.0, 'role': 'AXGroup'});
      expect(e2.label, 'AXGroup');
    });
  });

  group('ElementSnap.divergence', () {
    ElementSnap withWin(Rect win) => ElementSnap(
          rect: const Rect.fromLTWH(0, 0, 10, 10),
          role: 'AXButton', title: 't', app: 'a', latencyUs: 0,
          windowId: 1, winBounds: win,
        );

    test('null when winBounds or freezeRect missing', () {
      expect(withWin(const Rect.fromLTWH(0, 0, 100, 100)).divergence(null),
          isNull);
      const noWin = ElementSnap(
          rect: Rect.fromLTWH(0, 0, 10, 10),
          role: '', title: '', app: '', latencyUs: 0);
      expect(noWin.divergence(const Rect.fromLTWH(0, 0, 100, 100)), isNull);
    });

    test('reports translation and resize vs the freeze rect', () {
      final d = withWin(const Rect.fromLTWH(5, 8, 100, 100))
          .divergence(const Rect.fromLTWH(0, 0, 100, 100));
      expect(d!.dx, 5);
      expect(d.dy, 8);
      expect(d.resized, isFalse);

      final r = withWin(const Rect.fromLTWH(0, 0, 140, 100))
          .divergence(const Rect.fromLTWH(0, 0, 100, 100));
      expect(r!.resized, isTrue);
    });
  });
}
