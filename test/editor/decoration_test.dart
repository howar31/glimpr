import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/decoration.dart';

Future<ui.Image> _solid(int w, int h, ui.Color c) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = c,
  );
  final pic = recorder.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  return img;
}

Future<List<int>> _pixel(ui.Image img, int x, int y) async {
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final b = data!.buffer.asUint8List();
  final i = (y * img.width + x) * 4;
  return [b[i], b[i + 1], b[i + 2], b[i + 3]];
}

// No shadow / no rounding so the geometry asserts are exact.
const _plain = DecorationStyle(
  margin: 20,
  cornerRadius: 0,
  shadowBlur: 0,
  shadowOffset: ui.Offset.zero,
  shadowColor: ui.Color(0x00000000),
);

void main() {
  test('output size = content + 2*margin', () async {
    final c = await _solid(100, 60, const ui.Color(0xFFFF0000));
    final out = await applyDecoration(c, _plain);
    expect(out.width, 140);
    expect(out.height, 100);
  });

  test('PNG (fill null): corner margin pixel is transparent', () async {
    final c = await _solid(100, 60, const ui.Color(0xFFFF0000));
    final out = await applyDecoration(c, _plain);
    expect((await _pixel(out, 0, 0))[3], 0);
  });

  test('JPEG fill: margin pixel takes the fill colour, opaque', () async {
    final c = await _solid(100, 60, const ui.Color(0xFFFF0000));
    final out = await applyDecoration(c, _plain, fill: const ui.Color(0xFFFFFFFF));
    expect(await _pixel(out, 0, 0), [255, 255, 255, 255]);
  });

  test('content centre pixel is preserved', () async {
    final c = await _solid(100, 60, const ui.Color(0xFFFF0000));
    final out = await applyDecoration(c, _plain);
    // margin 20 + content centre (50,30)
    expect(await _pixel(out, 70, 50), [255, 0, 0, 255]);
  });

  test('effectiveMargin grows to cover the shadow reach', () {
    const s = DecorationStyle(
      margin: 10,
      cornerRadius: 0,
      shadowBlur: 24,
      shadowOffset: ui.Offset(0, 12),
      shadowColor: ui.Color(0x59000000),
    );
    expect(s.effectiveMargin, 36); // 24 + 12
  });

  test('scaled() multiplies the logical constants', () {
    final s = DecorationStyle.scaled(2.0);
    expect(s.margin, kDecorMarginLogical * 2.0);
    expect(s.cornerRadius, kDecorCornerRadiusLogical * 2.0);
    expect(s.shadowBlur, kDecorShadowBlurLogical * 2.0);
    expect(s.shadowOffset, kDecorShadowOffsetLogical * 2.0);
  });

  test('decorationSpecMap carries the values; fill omitted when null', () {
    final m = decorationSpecMap(
      margin: 120,
      cornerRadius: 24,
      shadowBlur: 28,
      shadowOffset: const ui.Offset(0, 12),
      shadowColorArgb: 0x59000000,
      shapeFromAlpha: false,
    );
    expect(m['margin'], 120);
    expect(m['cornerRadius'], 24);
    expect(m['shadowBlur'], 28);
    expect(m['shadowDx'], 0);
    expect(m['shadowDy'], 12);
    expect(m['shadowColor'], 0x59000000);
    expect(m['shapeFromAlpha'], false);
    expect(m.containsKey('fill'), false);
  });

  test('decorationSpecMap includes fill + shapeFromAlpha when set', () {
    final m = decorationSpecMap(
      margin: 1,
      cornerRadius: 0,
      shadowBlur: 0,
      shadowOffset: ui.Offset.zero,
      shadowColorArgb: 0,
      fillArgb: 0xFFFFFFFF,
      shapeFromAlpha: true,
    );
    expect(m['fill'], 0xFFFFFFFF);
    expect(m['shapeFromAlpha'], true);
  });

  test('logicalDecorationSpec mirrors the kDecor* constants', () {
    final m = logicalDecorationSpec(shapeFromAlpha: false);
    expect(m['margin'], kDecorMarginLogical);
    expect(m['cornerRadius'], kDecorCornerRadiusLogical);
    expect(m['shadowBlur'], kDecorShadowBlurLogical);
    expect(m['shadowDx'], kDecorShadowOffsetLogical.dx);
    expect(m['shadowDy'], kDecorShadowOffsetLogical.dy);
    expect(m['shadowColor'], kDecorShadowColor.toARGB32());
  });

  test('toNativeSpec carries the style\'s scaled (native-px) values', () {
    final s = DecorationStyle.scaled(2.0);
    final m = s.toNativeSpec(fillArgb: 0xFFFFFFFF, shapeFromAlpha: true);
    expect(m['margin'], kDecorMarginLogical * 2.0);
    expect(m['cornerRadius'], kDecorCornerRadiusLogical * 2.0);
    expect(m['shadowDy'], kDecorShadowOffsetLogical.dy * 2.0);
    expect(m['fill'], 0xFFFFFFFF);
    expect(m['shapeFromAlpha'], true);
  });

  test('shapeFromContentAlpha keeps the content alpha (no re-clip)', () async {
    // Content with a hard transparent right half (a stand-in window silhouette).
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      const ui.Rect.fromLTWH(0, 0, 50, 60),
      ui.Paint()..color = const ui.Color(0xFFFF0000),
    );
    final pic = rec.endRecording();
    final content = await pic.toImage(100, 60); // right half transparent
    pic.dispose();
    final out = await applyDecoration(content, _plain, shapeFromContentAlpha: true);
    expect(out.width, 140); // size = content + 2*margin
    expect(out.height, 100);
    // over the content's transparent half -> stays transparent (margin 20 +x=90)
    expect((await _pixel(out, 110, 50))[3], 0);
    // over the opaque half -> red (margin 20 + content x=10)
    expect(await _pixel(out, 30, 50), [255, 0, 0, 255]);
  });
}
