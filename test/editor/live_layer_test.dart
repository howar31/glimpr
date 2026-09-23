import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/live_layer.dart';

void main() {
  const style = DrawStyle();
  final doc = <Drawable>[
    const RectangleDrawable(Rect.fromLTWH(0, 0, 10, 10), style),
    HighlighterDrawable([const Offset(0, 0), const Offset(50, 0)], style),
  ];

  test('an ink preview goes to the live layer, the document stays settled', () {
    final live = HighlighterDrawable([const Offset(0, 20), const Offset(9, 20)], style);
    final r = partitionLiveLayer(doc, [live]);
    expect(r.settled, doc);
    expect(r.live, [live]);
  });

  test('no live candidate -> empty live layer', () {
    final r = partitionLiveLayer(doc, const []);
    expect(r.settled, doc);
    expect(r.live, isEmpty);
  });

  test('a spotlight preview joins the settled layer (shared background)', () {
    const live = SpotlightDrawable(Rect.fromLTWH(5, 5, 20, 20), style);
    final r = partitionLiveLayer(doc, [live]);
    expect(r.settled, [...doc, live]);
    expect(r.live, isEmpty);
  });

  test('blur / pixelate previews join the settled layer (under the dim)', () {
    const blur = BlurDrawable(Rect.fromLTWH(5, 5, 20, 20), style);
    const pix = PixelateDrawable(Rect.fromLTWH(5, 5, 20, 20), style);
    expect(partitionLiveLayer(doc, [blur]).live, isEmpty);
    expect(partitionLiveLayer(doc, [pix]).live, isEmpty);
    expect(partitionLiveLayer(doc, [blur]).settled.last, blur);
  });

  test('mixed candidates keep their order within each layer', () {
    const blur = BlurDrawable(Rect.fromLTWH(5, 5, 20, 20), style);
    final text = TextDrawable(const Offset(1, 1), 'x', style);
    final line = const LineDrawable(Offset(0, 0), Offset(1, 1), style);
    final r = partitionLiveLayer(doc, [line, blur, text]);
    expect(r.settled, [...doc, blur]);
    expect(r.live, [line, text]);
  });

  test('never mutates the input lists', () {
    final input = List<Drawable>.of(doc);
    partitionLiveLayer(input, [const LineDrawable(Offset(0, 0), Offset(1, 1), style)]);
    expect(input, doc);
  });
}
