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
      fittedSize: const Size(900, 675), // aspect-preserved fit of 4000x3000
      onComplete: () async => completed = true,
      activeSignal: ValueNotifier(
        (id: ImageEditorHost.kImageEditorHostId, cursor: Offset.zero),
      ),
    );
    expect(host.size, const Size(900, 675));
    // pixelScale maps fitted-logical -> native pixels.
    expect(host.pixelScale, closeTo(4000 / 900, 1e-9));
    expect(host.baseImage, same(image));
    expect(host.baseImageBytes, isNotNull);
    expect(host.cursorSeed, isNull);
    expect(host.startsActive, isTrue);
    expect(host.snapWindows, isEmpty);
    expect(host.rightClickExits, isFalse);
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
      fittedSize: const Size(10, 10),
      onComplete: () async {},
      activeSignal: ValueNotifier(
        (id: ImageEditorHost.kImageEditorHostId, cursor: Offset.zero),
      ),
      onClose: () => closed = true,
    );
    host.onCancel();
    expect(closed, isTrue);
  });
}
