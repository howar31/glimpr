import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/editor_controller.dart';

void main() {
  const r1 = Rect.fromLTWH(0, 0, 10, 10);
  const r2 = Rect.fromLTWH(20, 20, 10, 10);

  EditorController controllerWithSpots() {
    final c = EditorController();
    c.selectTool(ToolKind.spotlight);
    c.commitSpotlight(SpotlightDrawable(r1, c.style.value));
    c.commitSpotlight(SpotlightDrawable(r2, c.style.value));
    return c;
  }

  List<SpotlightDrawable> spots(EditorController c) =>
      c.document.value.drawables.whereType<SpotlightDrawable>().toList();

  test('layer change with tool active and NO selection fans out to all holes',
      () {
    final c = controllerWithSpots();
    expect(c.selectedIndex.value, isNull);
    c.setSpotlightDim(80);
    expect(spots(c).map((d) => d.style.spotlightDim), everyElement(80));
  });

  test('layer change fan-out is ONE undo step', () {
    final c = controllerWithSpots();
    final before = c.document.value.drawables;
    c.setSpotlightDim(80);
    final undone = c.document.value.undo();
    expect(undone.drawables, before);
  });

  test('layer change with a hole SELECTED fans out to all holes', () {
    final c = controllerWithSpots();
    c.selectedIndex.value = 0;
    c.setSpotlightFeather(8);
    expect(spots(c).map((d) => d.style.spotlightFeather), everyElement(8.0));
  });

  test('cornerRadius edit stays per-hole', () {
    final c = controllerWithSpots();
    c.selectedIndex.value = 0;
    c.setCornerRadius(9);
    final s = spots(c);
    expect(s[0].style.cornerRadius, 9);
    expect(s[1].style.cornerRadius, kCornerRadiusAuto);
  });

  test('commitSpotlight merges layer fields into existing holes in ONE commit',
      () {
    final c = EditorController();
    c.selectTool(ToolKind.spotlight);
    c.commitSpotlight(SpotlightDrawable(r1, c.style.value));
    // New hole arrives with different layer params (e.g. bar changed meanwhile).
    c.setSpotlightDim(70); // no holes selected -> sets tool default + fans out
    c.commitSpotlight(
        SpotlightDrawable(r2, c.style.value.copyWith(spotlightDim: 30)));
    expect(spots(c).map((d) => d.style.spotlightDim), everyElement(30));
    // One undo removes the new hole AND restores the old params together.
    c.undo();
    expect(spots(c).single.style.spotlightDim, 70);
  });

  test('no fan-out when a non-spotlight tool is active and nothing selected',
      () {
    final c = controllerWithSpots();
    c.selectTool(ToolKind.rectangle);
    c.setStrength(30); // shared field, but rectangle context
    expect(spots(c).map((d) => d.style.strength),
        everyElement(kRasterStrengthDefault));
  });

  test('setters clamp', () {
    final c = EditorController();
    c.selectTool(ToolKind.spotlight);
    c.setSpotlightDim(500);
    expect(c.style.value.spotlightDim, kSpotlightDimMax);
    c.setSpotlightFeather(-5);
    expect(c.style.value.spotlightFeather, kSpotlightFeatherMin);
  });
}
