import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/capture/direct_capture.dart';
import 'package:glimpr/capture/last_region.dart';

CapturedDisplay _disp(int id, {bool cursor = false, double w = 1920, double h = 1080}) =>
    CapturedDisplay(
      displayId: id,
      pngBytes: Uint8List(0),
      left: 0,
      top: 0,
      width: w,
      height: h,
      scaleFactor: 2,
      isCursorDisplay: cursor,
    );

void main() {
  group('resolveScreenTarget', () {
    test('picks the cursor display', () {
      final t = resolveScreenTarget([_disp(1), _disp(2, cursor: true)]);
      expect(t!.display.displayId, 2);
      expect(t.selectionLogical, isNull);
    });
    test('falls back to the first display when none is the cursor display', () {
      final t = resolveScreenTarget([_disp(5), _disp(6)]);
      expect(t!.display.displayId, 5);
    });
    test('returns null when there are no frames', () {
      expect(resolveScreenTarget(const []), isNull);
    });
  });

  group('resolveWindowTarget', () {
    test('targets the focused window rect on its display', () {
      final t = resolveWindowTarget([_disp(1, cursor: true), _disp(2)],
          const FocusedWindowInfo(
              displayId: 2,
              rect: Rect.fromLTWH(30, 40, 500, 360),
              title: 'Editor',
              app: 'Code'));
      expect(t!.display.displayId, 2);
      expect(t.selectionLogical, const Rect.fromLTWH(30, 40, 500, 360));
      expect(t.windowTitle, 'Editor');
      expect(t.appName, 'Code');
    });
    test('no focused window -> falls back to the cursor display, whole screen', () {
      final t = resolveWindowTarget([_disp(1), _disp(2, cursor: true)], null);
      expect(t!.display.displayId, 2);
      expect(t.selectionLogical, isNull);
    });
    test('focused window on an uncaptured display -> falls back to screen', () {
      final t = resolveWindowTarget([_disp(1, cursor: true)],
          const FocusedWindowInfo(
              displayId: 99,
              rect: Rect.fromLTWH(0, 0, 10, 10),
              title: '',
              app: ''));
      expect(t!.display.displayId, 1);
      expect(t.selectionLogical, isNull);
    });
  });

  group('resolveLastRegionTarget', () {
    test('crops the stored rect on the stored display', () {
      final t = resolveLastRegionTarget([_disp(3), _disp(4)],
          const LastRegion(displayId: 4, rect: Rect.fromLTWH(1, 2, 300, 200)));
      expect(t!.display.displayId, 4);
      expect(t.selectionLogical, const Rect.fromLTWH(1, 2, 300, 200));
    });
    test('null region -> null (no-op)', () {
      expect(resolveLastRegionTarget([_disp(3)], null), isNull);
    });
    test('stored display gone -> null (no-op)', () {
      final t = resolveLastRegionTarget([_disp(3)],
          const LastRegion(displayId: 99, rect: Rect.fromLTWH(0, 0, 5, 5)));
      expect(t, isNull);
    });
  });
}
