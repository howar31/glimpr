import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/gif_editor_controller.dart';

import '../support/gif_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GifEditorController c;

  setUp(() => c = GifEditorController());
  tearDown(() => c.dispose());

  test('openBytes builds the document and resets position', () async {
    expect(c.doc, isNull);
    await c.openBytes(twoFrameGifFixture());
    expect(c.doc!.frameCount, 2);
    expect(c.current, 0);
    expect(c.playing, isFalse);
    expect(c.opening, isFalse);
  });

  test('opening a second GIF replaces the document', () async {
    await c.openBytes(twoFrameGifFixture());
    final firstStore = c.store;
    c.seek(1);
    await c.openBytes(twoFrameGifFixture());
    expect(c.current, 0);
    expect(identical(c.store, firstStore), isFalse);
  });

  test('seek clamps to the frame range and notifies', () async {
    await c.openBytes(twoFrameGifFixture());
    var notified = 0;
    c.addListener(() => notified++);
    c.seek(1);
    expect(c.current, 1);
    c.seek(99);
    expect(c.current, 1); // clamped to last
    c.seek(-5);
    expect(c.current, 0);
    expect(notified, greaterThanOrEqualTo(2));
  });

  test('playback honors per-frame delays and wraps', () async {
    await c.openBytes(twoFrameGifFixture()); // delays 200ms, 400ms
    c.togglePlay();
    expect(c.playing, isTrue);
    // Frame 0 shows for 200ms, then frame 1.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.current, 1);
    // Frame 1 shows for 400ms, then wraps to frame 0.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.current, 0);
    c.togglePlay();
    expect(c.playing, isFalse);
    final frozen = c.current;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.current, frozen); // paused = no advance
  });

  test('seek while playing keeps playing from the new frame', () async {
    await c.openBytes(twoFrameGifFixture());
    c.togglePlay();
    c.seek(1);
    expect(c.playing, isTrue);
    expect(c.current, 1);
  });
}
