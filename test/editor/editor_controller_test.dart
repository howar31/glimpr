import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/editor_controller.dart';

void main() {
  test('starts in crop phase with the Crop tool (crop is the default)', () {
    final c = EditorController();
    expect(c.phase.value, EditorPhase.crop);
    expect(c.tool.value, ToolKind.crop);
    c.dispose();
  });

  test('switching to an annotation tool enters the annotate phase', () {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    expect(c.phase.value, EditorPhase.annotate);
    c.dispose();
  });

  test('commitDrawable adds to the document (undoable)', () {
    final c = EditorController();
    c.commitDrawable(
      const RectangleDrawable(Rect.fromLTWH(0, 0, 10, 10), DrawStyle()),
    );
    expect(c.document.value.drawables.length, 1);
    c.undo();
    expect(c.document.value.drawables, isEmpty);
    c.dispose();
  });

  test('setStyle updates the active style for new drawables', () {
    final c = EditorController();
    c.setColor(const Color(0xFF007AFF));
    expect(c.style.value.color, const Color(0xFF007AFF));
    c.dispose();
  });

  test('setColor also restyles the selected drawable (edit)', () {
    final c = EditorController();
    c.commitDrawable(
      const RectangleDrawable(Rect.fromLTWH(0, 0, 10, 10), DrawStyle()),
    );
    c.selectedIndex.value = 0;
    c.setColor(const Color(0xFF34C759));
    final d = c.document.value.drawables[0] as RectangleDrawable;
    expect(d.style.color, const Color(0xFF34C759));
    c.dispose();
  });

  test('editing a SELECTED drawable does not pollute the active tool default', () {
    final styles = <ToolKind, DrawStyle>{};
    final c = EditorController(toolStyles: styles);
    c.selectTool(ToolKind.rectangle);
    // No selection: setColor sets the rectangle tool's remembered default.
    c.setColor(const Color(0xFFFF0000));
    expect(styles[ToolKind.rectangle]?.color, const Color(0xFFFF0000));
    // Draw + select a rectangle, then edit its colour.
    c.commitDrawable(
      const RectangleDrawable(
        Rect.fromLTWH(0, 0, 10, 10),
        DrawStyle(color: Color(0xFFFF0000)),
      ),
    );
    c.selectedIndex.value = 0;
    c.setColor(const Color(0xFF00FF00));
    // The drawable changed...
    expect(
      (c.document.value.drawables[0] as RectangleDrawable).style.color,
      const Color(0xFF00FF00),
    );
    // ...but the tool default did NOT.
    expect(styles[ToolKind.rectangle]?.color, const Color(0xFFFF0000));
    // Deselecting restores the unpolluted tool default into the option bar.
    c.selectedIndex.value = null;
    expect(c.style.value.color, const Color(0xFFFF0000));
    c.dispose();
  });

  test('resetting a SELECTED drawable does not pollute the active tool default', () {
    final styles = <ToolKind, DrawStyle>{};
    final c = EditorController(toolStyles: styles);
    c.selectTool(ToolKind.rectangle);
    c.setColor(const Color(0xFFFF0000)); // tool default = red
    c.commitDrawable(
      const RectangleDrawable(
        Rect.fromLTWH(0, 0, 10, 10),
        DrawStyle(color: Color(0xFF00FF00)),
      ),
    );
    c.selectedIndex.value = 0;
    c.resetActiveStyle(ToolKind.rectangle); // resets ONLY the selected drawable
    expect(
      (c.document.value.drawables[0] as RectangleDrawable).style.color,
      const DrawStyle().color,
    );
    expect(styles[ToolKind.rectangle]?.color, const Color(0xFFFF0000));
    c.dispose();
  });

  test('selecting a blur region syncs its strength; editing it stays per-region', () {
    final styles = <ToolKind, DrawStyle>{};
    final c = EditorController(toolStyles: styles);
    c.selectTool(ToolKind.blur);
    c.commitDrawable(
      const BlurDrawable(Rect.fromLTWH(0, 0, 20, 20), DrawStyle()),
    );
    c.selectedIndex.value = 0;
    // Selecting a blur region loads its style (strength) into the option bar.
    expect(c.style.value.strength, kRasterStrengthDefault);
    c.setStrength(24);
    expect(
      (c.document.value.drawables[0] as BlurDrawable).style.strength,
      24,
    );
    // Editing a selected region must not pollute the tool default.
    expect(styles[ToolKind.blur], isNull);
    c.dispose();
  });

  test('enterCrop switches phase to crop', () {
    final c = EditorController();
    c.selectTool(ToolKind.crop);
    expect(c.phase.value, EditorPhase.crop);
    c.dispose();
  });

  RectangleDrawable r(double x) =>
      RectangleDrawable(Rect.fromLTWH(x, 0, 10, 10), const DrawStyle());

  test('duplicateSelected inserts an offset copy above the original and selects it', () {
    final c = EditorController();
    c.commitDrawable(r(0));
    c.selectedIndex.value = 0;
    c.duplicateSelected();
    expect(c.document.value.drawables.length, 2);
    expect(c.selectedIndex.value, 1);
    final copy = c.document.value.drawables[1] as RectangleDrawable;
    expect(copy.rect.left, kDuplicateOffset.dx);
    expect(copy.rect.top, kDuplicateOffset.dy);
    // The original is untouched.
    expect((c.document.value.drawables[0] as RectangleDrawable).rect.left, 0);
    c.dispose();
  });

  test('duplicateSelected is a no-op when nothing is selected', () {
    final c = EditorController();
    c.commitDrawable(r(0));
    c.selectedIndex.value = null;
    c.duplicateSelected();
    expect(c.document.value.drawables.length, 1);
    c.dispose();
  });

  test('bringSelectedToFront moves the selection to the top and tracks the index', () {
    final c = EditorController();
    c.commitDrawable(r(0));
    c.commitDrawable(r(1));
    c.commitDrawable(r(2));
    c.selectedIndex.value = 0;
    c.bringSelectedToFront();
    expect((c.document.value.drawables.last as RectangleDrawable).rect.left, 0);
    expect(c.selectedIndex.value, 2);
    c.dispose();
  });

  test('sendSelectedToBack moves the selection to the bottom and tracks the index', () {
    final c = EditorController();
    c.commitDrawable(r(0));
    c.commitDrawable(r(1));
    c.commitDrawable(r(2));
    c.selectedIndex.value = 2;
    c.sendSelectedToBack();
    expect((c.document.value.drawables.first as RectangleDrawable).rect.left, 2);
    expect(c.selectedIndex.value, 0);
    c.dispose();
  });

  test('bring/send are no-ops when already at the edge', () {
    final c = EditorController();
    c.commitDrawable(r(0));
    c.commitDrawable(r(1));
    final before = c.document.value.drawables.length;
    c.selectedIndex.value = 1;
    c.bringSelectedToFront(); // already last
    expect((c.document.value.drawables.last as RectangleDrawable).rect.left, 1);
    c.selectedIndex.value = 0;
    c.sendSelectedToBack(); // already first
    expect((c.document.value.drawables.first as RectangleDrawable).rect.left, 0);
    expect(c.document.value.drawables.length, before);
    c.dispose();
  });

  Future<ui.Image> testImage(int w, int h) {
    final done = Completer<ui.Image>();
    final pixels = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
    ui.decodeImageFromPixels(
        pixels, w, h, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  test('stamp image defaults null; setStampImage stores it', () async {
    final c = EditorController();
    expect(c.stampImage.value, isNull);
    final img = await testImage(2, 1);
    c.setStampImage(img);
    expect(c.stampImage.value, same(img));
    c.dispose();
  });

  test('requestStampPick bumps the stampPick channel', () {
    final c = EditorController();
    final before = c.stampPick.value;
    c.requestStampPick();
    expect(c.stampPick.value, before + 1);
    c.dispose();
  });

  test('setStamp sets both the image and the source bytes (for broadcast)', () async {
    final c = EditorController();
    final img = await testImage(2, 1);
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    c.setStamp(img, bytes);
    expect(c.stampImage.value, same(img));
    expect(c.stampBytes, same(bytes));
    c.dispose();
  });

  test('setMagnifyFactor clamps and restyles a selected magnify', () {
    final c = EditorController();
    c.commitDrawable(const MagnifyDrawable(
        Rect.fromLTWH(0, 0, 10, 10), Offset(100, 100), DrawStyle()));
    c.selectedIndex.value = 0;
    c.setMagnifyFactor(99); // clamps to max
    final m = c.document.value.drawables[0] as MagnifyDrawable;
    expect(m.style.magnifyFactor, kMagnifyFactorMax);
    expect(m.destRect.width, 10 * kMagnifyFactorMax);
    c.dispose();
  });
}
