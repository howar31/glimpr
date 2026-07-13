import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/frame_store.dart';
import 'package:glimpr/gif_editor/gif_document.dart';

GifFrame _frame(int key, int delayMs) =>
    GifFrame(key: FrameKey(key), width: 4, height: 4, delayMs: delayMs);

void main() {
  group('GifDocument', () {
    test('frameCount and totalDuration sum the frames', () {
      final doc = GifDocument(
        frames: [_frame(0, 200), _frame(1, 400), _frame(2, 30)],
        loopCount: 0,
      );
      expect(doc.frameCount, 3);
      expect(doc.totalDuration, const Duration(milliseconds: 630));
    });

    test('empty document is legal and zero-length', () {
      const doc = GifDocument(frames: [], loopCount: 0);
      expect(doc.frameCount, 0);
      expect(doc.totalDuration, Duration.zero);
    });

    test('withDelay copies a frame without mutating the original', () {
      final original = _frame(5, 100);
      final changed = original.withDelay(250);
      expect(original.delayMs, 100);
      expect(changed.delayMs, 250);
      expect(changed.key, original.key);
      expect(changed.width, original.width);
    });
  });
}
