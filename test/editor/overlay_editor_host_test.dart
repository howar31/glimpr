import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/editor/editor_host.dart';
import 'package:glimpr/overlay/overlay_editor_host.dart';

Future<ui.Image> _img(int w, int h) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  return recorder.endRecording().toImage(w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OverlayEditorHost maps CapturedDisplay to EditorHost getters', () async {
    final frozen = await _img(20, 10);
    final signal = ValueNotifier<({int id, Offset cursor})>((id: -1, cursor: Offset.zero));
    final display = CapturedDisplay(
      displayId: 7,
      rawBytes: Uint8List.fromList([1, 2, 3]),
      pixelWidth: 1,
      pixelHeight: 1,
      rowBytes: 4,
      left: 100,
      top: 50,
      width: 10,
      height: 5,
      scaleFactor: 2.0,
      isCursorDisplay: true,
      cursorX: 3,
      cursorY: 4,
      windows: const [SnapWindow(rect: Rect.fromLTWH(0, 0, 2, 2), title: 'T', app: 'A')],
    );
    var exported = false;
    var cancelled = false;
    final host = OverlayEditorHost(
      display: display,
      frozen: frozen,
      activeSignal: signal,
      rightClickExits: false,
      onExport: (rect, win) async => exported = true,
      onCancel: () => cancelled = true,
      cursor: const NoopCursorController(),
    );

    expect(host.size, const Size(10, 5));
    expect(host.pixelScale, 2.0);
    expect(host.baseImage, same(frozen));
    expect(host.cursorSeed, const Offset(3, 4));
    expect(host.startsActive, isTrue);
    expect(host.hostId, 7);
    expect(host.globalOrigin, const Offset(100, 50));
    expect(host.snapWindows.length, 1);
    expect(host.activeSignal, same(signal));
    expect(host.rightClickExits, isFalse);
    expect(host.viewportInteractive, isFalse);

    await host.onExport(null, null);
    host.onCancel();
    expect(exported, isTrue);
    expect(cancelled, isTrue);
  });
}
