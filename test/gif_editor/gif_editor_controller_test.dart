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

  Future<void> openN(List<int> colors, List<int> delays) =>
      c.openBytes(solidFramesGif(colors: colors, delays: delays));

  group('selection', () {
    test('plain select replaces and anchors', () async {
      await openN([0, 1, 2, 3], [100, 100, 100, 100]);
      c.select(2);
      expect(c.selection, {2});
      c.select(0);
      expect(c.selection, {0});
    });

    test('toggle adds and removes', () async {
      await openN([0, 1, 2, 3], [100, 100, 100, 100]);
      c.select(1);
      c.select(3, toggle: true);
      expect(c.selection, {1, 3});
      c.select(1, toggle: true);
      expect(c.selection, {3});
    });

    test('range selects from the anchor', () async {
      await openN([0, 1, 2, 3, 4], [100, 100, 100, 100, 100]);
      c.select(1);
      c.select(3, range: true);
      expect(c.selection, {1, 2, 3});
      // Range in the other direction from the same anchor.
      c.select(0, range: true);
      expect(c.selection, {0, 1});
    });

    test('selectAll and clearSelection', () async {
      await openN([0, 1, 2], [100, 100, 100]);
      c.selectAll();
      expect(c.selection, {0, 1, 2});
      c.clearSelection();
      expect(c.selection, isEmpty);
    });

    test('selection changes do not create undo history', () async {
      await openN([0, 1, 2], [100, 100, 100]);
      c.select(1);
      c.selectAll();
      expect(c.canUndo, isFalse);
    });
  });

  group('deleteSelected + undo/redo', () {
    test('removes the selected frames and collapses the selection',
        () async {
      await openN([0, 1, 2, 3], [100, 150, 200, 250]);
      c.select(1);
      c.select(2, toggle: true);
      c.deleteSelected();
      expect(c.doc!.frameCount, 2);
      expect(c.doc!.frames[0].delayMs, 100);
      expect(c.doc!.frames[1].delayMs, 250);
      // Selection lands on the frame now sitting at the first deleted slot.
      expect(c.selection, {1});
      expect(c.current, 1);
    });

    test('never deletes every frame', () async {
      await openN([0, 1], [100, 100]);
      c.selectAll();
      c.deleteSelected();
      expect(c.doc!.frameCount, 2); // refused
    });

    test('no selection is a no-op', () async {
      await openN([0, 1], [100, 100]);
      c.deleteSelected();
      expect(c.doc!.frameCount, 2);
      expect(c.canUndo, isFalse);
    });

    test('undo restores frames, selection and current; redo reapplies',
        () async {
      await openN([0, 1, 2], [100, 150, 200]);
      c.seek(2);
      c.select(2);
      c.deleteSelected();
      expect(c.doc!.frameCount, 2);
      expect(c.canUndo, isTrue);
      c.undo();
      expect(c.doc!.frameCount, 3);
      expect(c.doc!.frames[2].delayMs, 200);
      expect(c.selection, {2});
      expect(c.current, 2);
      expect(c.canRedo, isTrue);
      c.redo();
      expect(c.doc!.frameCount, 2);
      expect(c.canRedo, isFalse);
    });

    test('a new mutation clears the redo branch', () async {
      await openN([0, 1, 2, 3], [100, 100, 100, 100]);
      c.select(0);
      c.deleteSelected();
      c.undo();
      expect(c.canRedo, isTrue);
      c.select(1);
      c.deleteSelected();
      expect(c.canRedo, isFalse);
    });

    test('mutating while playing pauses playback', () async {
      await openN([0, 1, 2], [100, 100, 100]);
      c.togglePlay();
      expect(c.playing, isTrue);
      c.select(0);
      c.deleteSelected();
      expect(c.playing, isFalse);
    });

    test('undo history caps at 100 entries', () async {
      final colors = List.generate(120, (i) => i);
      await openN(colors, List.filled(120, 100));
      for (var i = 0; i < 105; i++) {
        c.select(0);
        c.deleteSelected();
      }
      expect(c.doc!.frameCount, 15);
      var undos = 0;
      while (c.canUndo) {
        c.undo();
        undos++;
      }
      expect(undos, 100);
      expect(c.doc!.frameCount, 115); // the 5 oldest deletes are gone
    });

    test('open and close clear the history', () async {
      await openN([0, 1, 2], [100, 100, 100]);
      c.select(0);
      c.deleteSelected();
      expect(c.canUndo, isTrue);
      await openN([0, 1], [100, 100]);
      expect(c.canUndo, isFalse);
      c.select(0);
      c.deleteSelected();
      c.close();
      expect(c.canUndo, isFalse);
      expect(c.selection, isEmpty);
    });
  });

  group('move/reverse/yoyo', () {
    List<int> delays() => [for (final f in c.doc!.frames) f.delayMs];

    test('moveSelected shifts the block and the selection follows',
        () async {
      await openN([0, 1, 2, 3], [100, 150, 200, 250]);
      c.select(1);
      c.select(2, toggle: true);
      c.moveSelected(-1);
      expect(delays(), [150, 200, 100, 250]);
      expect(c.selection, {0, 1});
      c.moveSelected(1);
      expect(delays(), [100, 150, 200, 250]);
      expect(c.selection, {1, 2});
    });

    test('blocked moves at the edges are complete no-ops', () async {
      await openN([0, 1, 2], [100, 150, 200]);
      c.select(0);
      c.select(1, toggle: true);
      c.moveSelected(-1);
      expect(delays(), [100, 150, 200]);
      expect(c.canUndo, isFalse);
      c.select(2);
      c.moveSelected(1);
      expect(delays(), [100, 150, 200]);
      expect(c.canUndo, isFalse);
    });

    test('reverse flips the contents at the selected positions', () async {
      await openN([0, 1, 2, 3, 4], [100, 150, 200, 250, 300]);
      c.select(1);
      c.select(3, range: true);
      c.reverse();
      expect(delays(), [100, 250, 200, 150, 300]);
      expect(c.selection, {1, 2, 3});
      c.undo();
      expect(delays(), [100, 150, 200, 250, 300]);
    });

    test('reverse with no selection flips the whole document', () async {
      await openN([0, 1, 2], [100, 150, 200]);
      c.reverse();
      expect(delays(), [200, 150, 100]);
    });

    test('yoyo appends the full reversed sequence', () async {
      await openN([0, 1], [100, 150]);
      c.yoyo();
      expect(delays(), [100, 150, 150, 100]);
      expect(c.doc!.frameCount, 4);
      c.undo();
      expect(c.doc!.frameCount, 2);
    });
  });

  test('close clears the document back to the landing state', () async {
    await c.openBytes(twoFrameGifFixture());
    c.togglePlay();
    c.close();
    expect(c.doc, isNull);
    expect(c.store, isNull);
    expect(c.playing, isFalse);
    expect(c.current, 0);
    // A new document opens normally afterwards.
    await c.openBytes(twoFrameGifFixture());
    expect(c.doc!.frameCount, 2);
  });
}
