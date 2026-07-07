import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/l10n/gen/app_localizations.dart';
import 'package:glimpr/overlay/style_popovers.dart';
import 'package:glimpr/theme/glimpr_controls.dart' show GlimprSlider, GlassToggle;

import '../support/localized_app.dart';

// Tests run in the English (template) locale; label assertions are English.
final AppLocalizations l10n = lookupAppLocalizations(const Locale('en'));

Future<void> _pump(WidgetTester t, Widget child) =>
    t.pumpWidget(localizedApp(Scaffold(body: child)));

void main() {
  // ---- LineStylePickerPopover -------------------------------------------

  testWidgets('line-style popover lists all styles, marks the selected, '
      'reports a pick', (t) async {
    LineStyle? picked;
    await _pump(
      t,
      LineStylePickerPopover(
        selected: LineStyle.solid,
        color: const Color(0xFF000000),
        onSelected: (s) => picked = s,
      ),
    );
    for (final s in LineStyle.values) {
      expect(find.text(lineStyleLabel(l10n, s)), findsOneWidget);
    }
    // The selected row carries the accent check.
    expect(find.byIcon(Icons.check), findsOneWidget);
    await t.tap(find.text(lineStyleLabel(l10n, LineStyle.dashed)));
    expect(picked, LineStyle.dashed);
  });

  // ---- TexturePickerPopover ---------------------------------------------

  testWidgets('texture popover lists textures, marks the selected, reports a '
      'pick', (t) async {
    HighlighterTexture? picked;
    await _pump(
      t,
      TexturePickerPopover(
        selected: HighlighterTexture.clean,
        color: const Color(0xFFFFFF00),
        onSelected: (x) => picked = x,
      ),
    );
    for (final tex in HighlighterTexture.values) {
      expect(find.text(textureLabel(l10n, tex)), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsOneWidget);
    await t.tap(find.text(textureLabel(l10n, HighlighterTexture.frayed)));
    expect(picked, HighlighterTexture.frayed);
  });

  // ---- ArrowHeadsPickerPopover ------------------------------------------

  testWidgets('arrowheads popover lists ends, marks the selected, reports a '
      'pick', (t) async {
    ArrowHeads? picked;
    await _pump(
      t,
      ArrowHeadsPickerPopover(
        selected: ArrowHeads.end,
        onSelected: (h) => picked = h,
      ),
    );
    for (final h in ArrowHeads.values) {
      expect(find.text(arrowHeadsLabel(l10n, h)), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsOneWidget);
    await t.tap(find.text(arrowHeadsLabel(l10n, ArrowHeads.both)));
    expect(picked, ArrowHeads.both);
  });

  // ---- StepShapePickerPopover -------------------------------------------

  testWidgets('step-shape popover lists shapes, marks the selected, reports a '
      'pick', (t) async {
    StepShape? picked;
    await _pump(
      t,
      StepShapePickerPopover(
        selected: StepShape.circle,
        onSelected: (s) => picked = s,
      ),
    );
    for (final s in StepShape.values) {
      expect(find.text(stepShapeLabel(l10n, s)), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsOneWidget);
    await t.tap(find.text(stepShapeLabel(l10n, StepShape.square)));
    expect(picked, StepShape.square);
  });

  // ---- SpotlightEffectPickerPopover -------------------------------------

  testWidgets('spotlight-effect popover lists treatments, marks the selected, '
      'reports a pick', (t) async {
    SpotlightEffect? picked;
    await _pump(
      t,
      SpotlightEffectPickerPopover(
        selected: SpotlightEffect.none,
        onSelected: (e) => picked = e,
      ),
    );
    for (final e in SpotlightEffect.values) {
      expect(find.text(spotlightEffectLabel(l10n, e)), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsOneWidget);
    await t.tap(find.text(spotlightEffectLabel(l10n, SpotlightEffect.blur)));
    expect(picked, SpotlightEffect.blur);
  });

  // ---- ChoiceListPopover -------------------------------------------------

  testWidgets('choice-list popover lists options, marks the selected, reports '
      'a pick', (t) async {
    String? picked;
    await _pump(
      t,
      ChoiceListPopover<String>(
        selected: 'a',
        options: const [('a', 'Alpha'), ('b', 'Beta'), ('c', 'Gamma')],
        onSelected: (v) => picked = v,
      ),
    );
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget); // selected 'a'
    await t.tap(find.text('Gamma'));
    expect(picked, 'c');
  });

  // ---- RadiusPickerPopover ----------------------------------------------

  testWidgets('radius popover: Auto hides the slider; turning Auto off seeds a '
      'baseline radius', (t) async {
    double? changed;
    var autoCalled = false;
    // Auto (value < 0): the explicit slider is hidden, the Auto toggle is on.
    await _pump(
      t,
      RadiusPickerPopover(
        value: -1,
        max: 100,
        onChanged: (v) => changed = v,
        onAuto: () => autoCalled = true,
      ),
    );
    expect(find.byType(GlimprSlider), findsNothing);
    expect(find.text(radiusLabel(l10n, -1)), findsWidgets); // "Auto" somewhere
    // Turning Auto off seeds an explicit baseline via onChanged (not onAuto).
    await t.tap(find.byType(GlassToggle));
    await t.pump();
    expect(changed, isNotNull);
    expect(autoCalled, isFalse);
  });

  testWidgets('radius popover: an explicit radius shows the slider', (t) async {
    await _pump(
      t,
      RadiusPickerPopover(
        value: 20,
        max: 100,
        onChanged: (_) {},
        onAuto: () {},
      ),
    );
    expect(find.byType(GlimprSlider), findsOneWidget);
    // The pill label reads the explicit pixel value, not "Auto".
    expect(radiusLabel(l10n, 20), '20 px');
  });

  // ---- ColorPickerPopover: SV plane + alpha ------------------------------

  testWidgets('tapping the SV plane commits a colour', (t) async {
    Color? committed;
    await _pump(
      t,
      ColorPickerPopover(
        color: const Color(0xFFFF0000),
        recents: const [],
        onChanged: (_) {},
        onCommit: (c) => committed = c,
      ),
    );
    final sv = find.byWidgetPredicate((w) =>
        w is CustomPaint &&
        w.painter.runtimeType.toString() == '_SVPlanePainter');
    expect(sv, findsOneWidget);
    await t.tapAt(t.getCenter(sv));
    await t.pump();
    expect(committed, isNotNull);
  });

  testWidgets('dragging the alpha slider makes the colour translucent',
      (t) async {
    Color? changed;
    await _pump(
      t,
      ColorPickerPopover(
        color: const Color(0xFFFF0000),
        recents: const [],
        onChanged: (c) => changed = c,
        onCommit: (_) {},
      ),
    );
    // The alpha track is the checkerboard-backed gradient slider.
    final alpha = find.byWidgetPredicate((w) =>
        w is CustomPaint &&
        w.painter.runtimeType.toString() == '_GradientSliderPainter' &&
        (w.painter as dynamic).checkerboard == true);
    expect(alpha, findsOneWidget);
    // Drag left toward the transparent end (a small first move engages the
    // horizontal-drag recogniser).
    final g = await t.startGesture(t.getCenter(alpha));
    await g.moveBy(const Offset(-30, 0));
    await t.pump();
    await g.moveBy(const Offset(-120, 0));
    await t.pump();
    await g.up();
    await t.pump();
    expect(changed, isNotNull);
    expect(changed!.a, lessThan(1.0));
  });

  testWidgets('a provided recent swatch commits its colour', (t) async {
    Color? committed;
    const recent = 0xFF00FF00;
    await _pump(
      t,
      ColorPickerPopover(
        color: const Color(0xFFFF0000),
        recents: const [recent],
        onChanged: (_) {},
        onCommit: (c) => committed = c,
      ),
    );
    // The recents Wrap is the last section; its swatch is the only tappable
    // swatch carrying the recent colour (presets never include pure green here).
    final swatch = find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).color == const Color(recent));
    expect(swatch, findsOneWidget);
    await t.tap(swatch);
    await t.pump();
    expect(committed, const Color(recent));
  });
}
