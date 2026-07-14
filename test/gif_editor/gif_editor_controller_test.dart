import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/gif_editor/encode/gif_writer.dart';
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

  group('removeDuplicates / reduceFrames', () {
    List<int> delays() => [for (final f in c.doc!.frames) f.delayMs];

    test('collapses consecutive identical frames and merges delays',
        () async {
      await openN([0, 1, 1, 2], [100, 150, 200, 250]);
      c.removeDuplicates();
      expect(delays(), [100, 350, 250]);
      expect(c.selection, isEmpty);
      c.undo();
      expect(delays(), [100, 150, 200, 250]);
    });

    test('non-consecutive duplicates survive', () async {
      await openN([1, 0, 1], [100, 150, 200]);
      c.removeDuplicates();
      expect(c.doc!.frameCount, 3);
      expect(c.canUndo, isFalse); // nothing changed, no history entry
    });

    test('reduceFrames keeps every nth and preserves total duration',
        () async {
      await openN([0, 1, 2, 3, 4], [100, 100, 100, 100, 100]);
      c.seek(3);
      c.reduceFrames(2);
      expect(delays(), [200, 200, 100]);
      expect(c.doc!.totalDuration.inMilliseconds, 500);
      expect(c.current, 1); // playhead lands on its group's survivor
      c.undo();
      expect(delays(), [100, 100, 100, 100, 100]);
    });

    test('reduceFrames on a single frame is a no-op', () async {
      await openN([0], [100]);
      c.reduceFrames(2);
      expect(c.doc!.frameCount, 1);
      expect(c.canUndo, isFalse);
    });
  });

  group('delay ops', () {
    List<int> delays() => [for (final f in c.doc!.frames) f.delayMs];

    test('overrideDelay hits the selection, or all when none', () async {
      await openN([0, 1, 2], [100, 150, 200]);
      c.select(1);
      c.overrideDelay(500);
      expect(delays(), [100, 500, 200]);
      c.clearSelection();
      c.overrideDelay(80);
      expect(delays(), [80, 80, 80]);
      c.undo();
      expect(delays(), [100, 500, 200]);
    });

    test('shiftDelay clamps at the 10ms floor', () async {
      await openN([0, 1], [100, 30]);
      c.shiftDelay(-50);
      expect(delays(), [50, 10]);
      c.shiftDelay(25);
      expect(delays(), [75, 35]);
    });

    test('scaleDelay scales by percent and rounds', () async {
      await openN([0, 1], [100, 150]);
      c.scaleDelay(50);
      expect(delays(), [50, 75]);
      c.scaleDelay(1); // 1% of tiny values clamps to the floor
      expect(delays(), [10, 10]);
    });

    test('a delay op that changes nothing leaves no history', () async {
      await openN([0, 1], [100, 100]);
      c.overrideDelay(100);
      expect(c.canUndo, isFalse);
    });
  });

  group('frame clipboard', () {
    List<int> delays() => [for (final f in c.doc!.frames) f.delayMs];

    test('copy + paste inserts after the current frame', () async {
      await openN([0, 1, 2, 3], [100, 150, 200, 250]);
      c.select(1);
      c.select(2, toggle: true);
      c.copySelected();
      expect(c.clipboardHasFrames, isTrue);
      expect(c.doc!.frameCount, 4); // copy does not mutate
      c.seek(3);
      c.pasteFrames();
      expect(delays(), [100, 150, 200, 250, 150, 200]);
      expect(c.selection, {4, 5});
      expect(c.current, 4);
      c.undo();
      expect(delays(), [100, 150, 200, 250]);
    });

    test('cut removes and paste restores the content', () async {
      await openN([0, 1, 2], [100, 150, 200]);
      c.select(1);
      c.cutSelected();
      expect(delays(), [100, 200]);
      expect(c.clipboardHasFrames, isTrue);
      c.seek(1);
      c.pasteFrames();
      expect(delays(), [100, 200, 150]);
    });

    test('cutting every frame is refused', () async {
      await openN([0, 1], [100, 150]);
      c.selectAll();
      c.cutSelected();
      expect(c.doc!.frameCount, 2);
      expect(c.clipboardHasFrames, isFalse);
    });

    test('a new document clears the clipboard (stale store keys)',
        () async {
      await openN([0, 1], [100, 150]);
      c.select(0);
      c.copySelected();
      expect(c.clipboardHasFrames, isTrue);
      await openN([0, 1], [100, 150]);
      expect(c.clipboardHasFrames, isFalse);
    });
  });

  group('canvas ops', () {
    // A 2x2 frame with four exactly-representable distinct colors laid out
    // [R G / B W]; position checks read the raw store bytes back.
    final quad = Uint8List.fromList([
      255, 0, 0, 255, //
      0, 255, 0, 255, //
      0, 0, 255, 255, //
      255, 255, 255, 255, //
    ]);

    Future<void> openQuad() => c.openBytes(encodeGifFrames(
          frames: [FrameSpec(quad, 100), FrameSpec(quad, 150)],
          width: 2,
          height: 2,
          loopCount: 0,
        ));

    Uint8List frameBytes(int i) =>
        File(c.store!.pathFor(c.doc!.frames[i].key)).readAsBytesSync();

    test('flipDoc horizontal mirrors every frame and is undoable',
        () async {
      await openQuad();
      await c.flipDoc(horizontal: true);
      expect(
          frameBytes(0),
          Uint8List.fromList([
            0, 255, 0, 255, 255, 0, 0, 255, //
            255, 255, 255, 255, 0, 0, 255, 255, //
          ]));
      expect(c.doc!.frames[1].delayMs, 150); // delays preserved
      expect(c.transforming, isFalse);
      c.undo();
      expect(frameBytes(0), quad);
    });

    test('rotateDoc swaps dimensions and places pixels correctly',
        () async {
      await openQuad();
      await c.rotateDoc(1); // clockwise: [B R / W G]
      expect(c.doc!.frames[0].width, 2);
      expect(c.doc!.frames[0].height, 2);
      expect(
          frameBytes(0),
          Uint8List.fromList([
            0, 0, 255, 255, 255, 0, 0, 255, //
            255, 255, 255, 255, 0, 255, 0, 255, //
          ]));
      await c.rotateDoc(-1); // back
      expect(frameBytes(0), quad);
    });

    test('cropDoc cuts every frame to the rect', () async {
      await openQuad();
      await c.cropDoc(1, 0, 1, 2); // right column: [G / W]
      expect(c.doc!.frames[0].width, 1);
      expect(c.doc!.frames[0].height, 2);
      expect(
          frameBytes(0),
          Uint8List.fromList([
            0, 255, 0, 255, //
            255, 255, 255, 255, //
          ]));
      c.undo();
      expect(c.doc!.frames[0].width, 2);
      expect(frameBytes(0), quad);
    });

    test('full-frame crop and same-size resize are no-ops', () async {
      await openQuad();
      await c.cropDoc(0, 0, 2, 2);
      await c.resizeDoc(2, 2);
      expect(c.canUndo, isFalse);
    });

    test('resizeDoc scales dimensions and keeps solids solid', () async {
      final solid = Uint8List(2 * 2 * 4);
      for (var i = 0; i < 4; i++) {
        solid[i * 4] = 40;
        solid[i * 4 + 1] = 80;
        solid[i * 4 + 2] = 120;
        solid[i * 4 + 3] = 255;
      }
      await c.openBytes(encodeGifFrames(
        frames: [FrameSpec(solid, 100)],
        width: 2,
        height: 2,
        loopCount: 0,
      ));
      await c.resizeDoc(4, 4);
      expect(c.doc!.frames[0].width, 4);
      expect(c.doc!.frames[0].height, 4);
      final out = frameBytes(0);
      expect(out.length, 4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        expect([out[i * 4], out[i * 4 + 1], out[i * 4 + 2]], [40, 80, 120]);
      }
    });

    test('progress reports and duplicate detection works on new frames',
        () async {
      await openQuad();
      final seen = <double>[];
      c.addListener(() {
        if (c.transforming) seen.add(c.transformProgress);
      });
      await c.flipDoc(horizontal: false);
      expect(seen, isNotEmpty);
      // Both frames were identical before and stay identical after the
      // flip: the new store entries carry hashes, so dedupe still works.
      c.removeDuplicates();
      expect(c.doc!.frameCount, 1);
      expect(c.doc!.frames[0].delayMs, 250);
    });
  });

  group('burn-in', () {
    // 8x8 solid dark-blue frames; a filled green rect bakes into the middle.
    Uint8List blueFrame() {
      final f = Uint8List(8 * 8 * 4);
      for (var i = 0; i < 64; i++) {
        f[i * 4 + 2] = 200;
        f[i * 4 + 3] = 255;
      }
      return f;
    }

    Future<void> openThree() => c.openBytes(encodeGifFrames(
          frames: [
            FrameSpec(blueFrame(), 100),
            FrameSpec(blueFrame(), 150),
            FrameSpec(blueFrame(), 200),
          ],
          width: 8,
          height: 8,
          loopCount: 0,
        ));

    Uint8List frameBytes(int i) =>
        File(c.store!.pathFor(c.doc!.frames[i].key)).readAsBytesSync();

    List<int> px(Uint8List rgba, int x, int y) =>
        [for (var k = 0; k < 4; k++) rgba[(y * 8 + x) * 4 + k]];

    const greenFill = DrawStyle(
      color: Color(0xFF00FF00),
      fillColor: Color(0xFF00FF00),
      strokeWidth: 1,
    );
    const rect = RectangleDrawable(Rect.fromLTWH(2, 2, 4, 4), greenFill);

    test('bakes onto the selected frames only, undoably', () async {
      await openThree();
      c.select(1);
      await c.bakeDrawables(const [rect]);
      expect(c.transforming, isFalse);
      // Frame 1: rect center is pure green; frame 0/2 untouched blue.
      expect(px(frameBytes(1), 4, 4), [0, 255, 0, 255]);
      expect(px(frameBytes(0), 4, 4), [0, 0, 200, 255]);
      expect(px(frameBytes(2), 4, 4), [0, 0, 200, 255]);
      // Outside the rect stays blue on the baked frame too.
      expect(px(frameBytes(1), 0, 0), [0, 0, 200, 255]);
      expect(c.doc!.frames[1].delayMs, 150);
      c.undo();
      expect(px(frameBytes(1), 4, 4), [0, 0, 200, 255]);
    });

    test('empty selection bakes every frame', () async {
      await openThree();
      await c.bakeDrawables(const [rect]);
      for (var i = 0; i < 3; i++) {
        expect(px(frameBytes(i), 4, 4), [0, 255, 0, 255],
            reason: 'frame $i must carry the bake');
      }
    });

    test('progress bar grows with elapsed time on every frame', () async {
      await openThree(); // delays 100/150/200 -> totals 100/250/450 of 450
      await c.bakeProgressBar(color: const Color(0xFFFF0000));
      // Bottom row, near-left pixel is red everywhere.
      expect(px(frameBytes(0), 0, 7), [255, 0, 0, 255]);
      // Frame 0 covers ~22% (100/450): x=6 stays blue; frame 2 covers all.
      expect(px(frameBytes(0), 6, 7), [0, 0, 200, 255]);
      expect(px(frameBytes(2), 7, 7), [255, 0, 0, 255]);
      // Rows above the 4px bar stay blue.
      expect(px(frameBytes(2), 7, 3), [0, 0, 200, 255]);
      c.undo();
      expect(px(frameBytes(0), 0, 7), [0, 0, 200, 255]);
    });

    test('insertTitleFrame adds a black 1s frame before the current',
        () async {
      await openThree();
      c.seek(1);
      await c.insertTitleFrame();
      expect(c.doc!.frameCount, 4);
      expect(c.doc!.frames[1].delayMs, 1000);
      expect(px(frameBytes(1), 4, 4), [0, 0, 0, 255]);
      expect(c.current, 1);
      expect(c.selection, {1});
      // The old frame 1 slid to index 2.
      expect(c.doc!.frames[2].delayMs, 150);
      c.undo();
      expect(c.doc!.frameCount, 3);
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
