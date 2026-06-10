import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/image_editor_host.dart';

Future<ui.Image> _img(int w, int h) {
  final r = ui.PictureRecorder();
  ui.Canvas(r);
  return r.endRecording().toImage(w, h);
}

void main() {
  test('ImageEditorHost maps a loaded image to EditorHost getters', () async {
    final image = await _img(4000, 3000);
    var completed = false;
    final host = ImageEditorHost(
      image: image,
      bytes: Uint8List.fromList([1, 2, 3]),
      onComplete: () async => completed = true,
      activeSignal: ValueNotifier((
        id: ImageEditorHost.kImageEditorHostId,
        cursor: Offset.zero,
      )),
    );
    // The logical canvas IS the image's native pixel grid; EditorCore fits it
    // via its viewport, so size == native size and pixelScale == 1.0.
    expect(host.size, const Size(4000, 3000));
    expect(host.pixelScale, 1.0);
    expect(host.baseImage, same(image));
    expect(host.cursorSeed, isNull);
    expect(host.startsActive, isTrue);
    expect(host.snapWindows, isEmpty);
    expect(host.rightClickExits, isFalse);
    expect(host.viewportInteractive, isTrue);
    // The active signal's id matches hostId, so EditorCore stays active.
    expect(host.activeSignal.value.id, host.hostId);
    await host.onExport(null, null);
    expect(completed, isTrue);
  });

  test('ImageEditorHost.onCancel invokes the onClose callback', () async {
    final image = await _img(10, 10);
    var closed = false;
    final host = ImageEditorHost(
      image: image,
      bytes: Uint8List.fromList([0]),
      onComplete: () async {},
      activeSignal: ValueNotifier((
        id: ImageEditorHost.kImageEditorHostId,
        cursor: Offset.zero,
      )),
      onClose: () => closed = true,
    );
    host.onCancel();
    expect(closed, isTrue);
  });
}
