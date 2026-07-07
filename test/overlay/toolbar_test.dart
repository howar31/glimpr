import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/editor/tool_meta.dart';
import 'package:glimpr/l10n/gen/app_localizations.dart';
import 'package:glimpr/overlay/style_popovers.dart';
import 'package:glimpr/overlay/toolbar.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';
import 'package:glimpr/theme/glimpr_theme.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../support/localized_app.dart';

// Tests run in the English (template) locale; label assertions are English.
final AppLocalizations l10n = lookupAppLocalizations(const Locale('en'));

// Pumps a toolbar with the given editor bindings. The default tool is Crop,
// which has no options row, so the ONLY Text widgets are the per-tool badges —
// letting tests count badges by Text count.
Future<EditorController> _pumpToolbar(
  WidgetTester tester,
  Map<String, HotkeyBinding?> bindings,
) async {
  final c = EditorController();
  addTearDown(c.dispose);
  await tester.pumpWidget(
    localizedApp(
      Scaffold(
        body: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: EditorToolbar(
            controller: c,
            onMove: (_) {},
            onPtEditingDone: () {},
            editorBindings: bindings,
          ),
        ),
      ),
    ),
  );
  return c;
}

// Pumps the toolbar on a WIDE surface (so a tool's whole option row is on-screen
// and its pills are hittable) with [tool] selected.
Future<EditorController> _pumpWide(WidgetTester tester, ToolKind tool) async {
  tester.view.physicalSize = const Size(1800, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = EditorController();
  addTearDown(c.dispose);
  c.selectTool(tool);
  await tester.pumpWidget(
    localizedApp(
      Scaffold(
        body: Center(
          child: EditorToolbar(
            controller: c,
            onMove: (_) {},
            onPtEditingDone: () {},
            editorBindings: kDefaultBindings,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return c;
}

// A RecordOverrides seeded for a normal (non-GIF) H.264 take, unless [gif].
RecordOverrides _overrides({bool gif = false}) => RecordOverrides(
      showCursor: true,
      systemAudio: false,
      microphone: false,
      hevc: false,
      hdr: false,
      gif: gif,
      fps: 30,
      gifFps: 15,
      maxDuration: 0,
    );

// Pumps the record live-select toolbar variant (region-only + record overrides).
Future<EditorController> _pumpRecord(
    WidgetTester tester, RecordOverrides o) async {
  tester.view.physicalSize = const Size(1800, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = EditorController();
  addTearDown(c.dispose);
  await tester.pumpWidget(
    localizedApp(
      Scaffold(
        body: Center(
          child: EditorToolbar(
            controller: c,
            onMove: (_) {},
            onPtEditingDone: () {},
            editorBindings: kDefaultBindings,
            recordMode: true,
            recordOverrides: o,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return c;
}

/// Smoke test: the toolbar must build all tool buttons (catches a bad IconData)
/// and rebuild the contextual options row for EVERY tool without throwing
/// (exercises each ToolKind branch in the options row, incl. text/step font).
void main() {
  testWidgets('builds every tool and every tool options row', (tester) async {
    final c = await _pumpToolbar(tester, kDefaultBindings);

    expect(kEditorToolMeta.length, 15);
    // 15 tool buttons + 2 HUD toggles (crosshair / loupe).
    expect(find.byType(IconButton), findsNWidgets(17));

    for (final (kind, _) in kEditorToolMeta) {
      c.selectTool(kind);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'options row for $kind');
    }
  });

  testWidgets('badges render each tool\'s default binding label',
      (tester) async {
    await _pumpToolbar(tester, kDefaultBindings);

    // Default tool is Crop => no options row => 15 tool badges + 2 HUD-toggle
    // badges (crosshair X / loupe Q), all default-bound.
    expect(find.byType(Text), findsNWidgets(17));
    // Crop's default is bare 'C'; Rectangle's is bare '1'. Both are
    // host-platform-stable (no modifier glyphs).
    expect(find.text('C'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('5'), findsOneWidget); // Pen
  });

  testWidgets('badges track a rebound (custom) binding', (tester) async {
    // Rebind Crop from bare 'C' to bare 'Y' (not 'X' — that is the crosshair
    // toggle's default, so the rebound label stays unique); its badge must follow.
    final bindings = {
      ...kDefaultBindings,
      kEditorToolActionKey[ToolKind.crop]!: const HotkeyBinding(
        physicalKey: PhysicalKeyboardKey.keyY,
        logicalKey: LogicalKeyboardKey.keyY,
        modifiers: {},
      ),
    };
    await _pumpToolbar(tester, bindings);

    expect(find.text('Y'), findsOneWidget); // the rebound label shows
    expect(find.text('C'), findsNothing); // the old label is gone
    // 15 tool badges + 2 HUD-toggle badges (crosshair X / loupe Q).
    expect(find.byType(Text), findsNWidgets(17));
  });

  testWidgets('an unbound tool shows no badge (button still builds)',
      (tester) async {
    // Map Crop's action to null (unbound) — its badge must disappear while the
    // tool button still builds.
    final bindings = {
      ...kDefaultBindings,
      kEditorToolActionKey[ToolKind.crop]!: null,
    };
    await _pumpToolbar(tester, bindings);

    expect(find.byType(IconButton), findsNWidgets(17)); // 15 tools + 2 HUD toggles
    expect(find.text('C'), findsNothing); // crop's badge is suppressed
    expect(find.byType(Text), findsNWidgets(16)); // 14 tool + 2 HUD-toggle badges
  });

  testWidgets('empty bindings => no badges at all', (tester) async {
    await _pumpToolbar(tester, const {});

    expect(find.byType(IconButton), findsNWidgets(17)); // 15 tools + 2 HUD toggles
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('every tool button has a tooltip with the shared tool label',
      (tester) async {
    await _pumpToolbar(tester, kDefaultBindings);

    // toolLabel is the SAME source the Settings > Shortcuts rows render, so
    // the tooltip text can never drift from the shortcut row's title.
    for (final (kind, _) in kEditorToolMeta) {
      expect(find.byTooltip(toolLabel(l10n, kind)), findsOneWidget,
          reason: 'tooltip for $kind');
    }
  });

  testWidgets('pin mode renames the crop slot tooltip to Pin', (tester) async {
    // Wide surface: pin mode adds the in-bar Pin chip and the full bar
    // exceeds the 800px default test width.
    tester.view.physicalSize = const Size(1600, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = EditorController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: EditorToolbar(
              controller: c,
              onMove: (_) {},
              onPtEditingDone: () {},
              editorBindings: kDefaultBindings,
              pinMode: true,
            ),
          ),
        ),
      ),
    );

    // The crop slot IS the pin region selector in pin mode.
    expect(find.byTooltip('Pin'), findsOneWidget);
    expect(find.byTooltip('Crop'), findsNothing);
    // Every other tool keeps its normal label.
    expect(find.byTooltip('Rectangle'), findsOneWidget);
  });

  testWidgets(
      'one caption line below the bar; the bottom-anchored bar never moves',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = EditorController();
    addTearDown(c.dispose);
    // Bottom-anchor like the overlay host. The caption space below the bar is
    // exactly ONE line: pin + layer messages merge into a single bar there,
    // painted via zero-height overflow so the tool row never moves.
    Future<void> pump(
            {String? caption, bool accent = false, bool pin = false}) =>
        tester.pumpWidget(
          localizedApp(
            Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: 0,
                    bottom: 120,
                    child: Material(
                      type: MaterialType.transparency,
                      child: EditorToolbar(
                        controller: c,
                        onMove: (_) {},
                        onPtEditingDone: () {},
                        editorBindings: const {},
                        pinMode: pin,
                        layerCaption: caption,
                        layerAccent: accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

    await pump();
    expect(find.byIcon(Icons.layers), findsNothing);
    final barAt = tester.getTopLeft(find.byType(IconButton).first);
    final barBottom = tester.getBottomLeft(find.byType(IconButton).first).dy;

    await pump(caption: 'Layers: 2/3');
    expect(find.text('Layers: 2/3'), findsOneWidget);
    expect(find.byIcon(Icons.layers), findsOneWidget);
    // The bar did not move; the caption sits BELOW the bar's bottom edge.
    expect(tester.getTopLeft(find.byType(IconButton).first), barAt);
    expect(tester.getTopLeft(find.text('Layers: 2/3')).dy,
        greaterThan(barBottom));

    await pump(caption: 'Layer replaced (1/1)', accent: true);
    expect(find.text('Layer replaced (1/1)'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(IconButton).first), barAt);

    // Pin + layer captions merge into the SAME single line (one bar).
    await pump(pin: true, caption: 'Layers: 2/3');
    expect(tester.getTopLeft(find.byType(IconButton).first), barAt);
    final pinDy = tester
        .getCenter(find.text('Pin mode: the selection floats as a pin'))
        .dy;
    final layerDy = tester.getCenter(find.text('Layers: 2/3')).dy;
    expect(pinDy, layerDy);
    expect(pinDy, greaterThan(barBottom));
  });

  test('the Settings row label combines the crop-slot contexts', () {
    expect(toolSettingsLabel(l10n, ToolKind.crop), 'Crop / Pin / Record');
    expect(toolLabel(l10n, ToolKind.crop), 'Crop');
    expect(toolLabel(l10n, ToolKind.crop, pinMode: true), 'Pin');
    expect(toolLabel(l10n, ToolKind.crop, recordMode: true), 'Record');
    // Every other tool's Settings row matches its tooltip exactly.
    for (final (kind, _) in kEditorToolMeta) {
      if (kind == ToolKind.crop) continue;
      expect(toolSettingsLabel(l10n, kind), toolLabel(l10n, kind));
      expect(toolLabel(l10n, kind, pinMode: true), toolLabel(l10n, kind));
      expect(toolLabel(l10n, kind, recordMode: true), toolLabel(l10n, kind));
    }
  });

  // ---- HUD toggles -------------------------------------------------------

  testWidgets(
      'HUD toggles are accent when on and greyed + inert for tools they '
      'do not apply to', (tester) async {
    final c = await _pumpToolbar(tester, kDefaultBindings);
    final crosshair = find.widgetWithIcon(IconButton, Icons.gps_fixed);
    final loupe = find.widgetWithIcon(IconButton, Icons.search);
    // Default tool is Crop: both HUD elements apply and default ON -> accent.
    expect(tester.widget<IconButton>(crosshair).color, GlimprTokens.accent);
    expect(tester.widget<IconButton>(loupe).color, GlimprTokens.accent);
    expect(tester.widget<IconButton>(crosshair).onPressed, isNotNull);

    // Text tool: neither crosshair nor loupe applies -> the buttons grey out
    // (opacity 0.35) and go inert (onPressed null).
    c.selectTool(ToolKind.text);
    await tester.pump();
    expect(tester.widget<IconButton>(crosshair).onPressed, isNull);
    final op = tester.widget<Opacity>(
      find.ancestor(of: crosshair, matching: find.byType(Opacity)).first,
    );
    expect(op.opacity, 0.35);
  });

  testWidgets('tapping a HUD toggle flips the controller state', (tester) async {
    final c = await _pumpToolbar(tester, kDefaultBindings);
    expect(c.crosshairOn.value, isTrue);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.gps_fixed));
    await tester.pump();
    expect(c.crosshairOn.value, isFalse);
    // Now greyed-off (still applies, so still enabled) shows the fg colour, not
    // accent.
    expect(
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.gps_fixed))
          .color,
      isNot(GlimprTokens.accent),
    );
  });

  // ---- style-popover openers --------------------------------------------

  testWidgets('the line-style pill opens the line-style popover',
      (tester) async {
    await _pumpWide(tester, ToolKind.line);
    expect(find.byType(LineStylePickerPopover), findsNothing);
    await tester.tap(find.byKey(const ValueKey('line-style-picker')));
    await tester.pump();
    expect(find.byType(LineStylePickerPopover), findsOneWidget);
  });

  testWidgets('the texture pill opens the highlighter-texture popover',
      (tester) async {
    await _pumpWide(tester, ToolKind.highlighter);
    await tester.tap(find.byKey(const ValueKey('texture-picker')));
    await tester.pump();
    expect(find.byType(TexturePickerPopover), findsOneWidget);
  });

  testWidgets('the colour swatch opens the colour picker popover',
      (tester) async {
    // The colour popover loads recent colours from Settings.instance — back it
    // with an in-memory prefs platform.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await _pumpWide(tester, ToolKind.rectangle);
    await tester.tap(find.byTooltip('Colour'));
    await tester.pumpAndSettle();
    expect(find.byType(ColorPickerPopover), findsOneWidget);
  });

  // ---- record-mode variant ----------------------------------------------

  testWidgets(
      'record mode shows the region selector + one-shot overrides, hides the '
      'annotation tools and HUD toggles', (tester) async {
    final o = _overrides();
    addTearDown(o.dispose);
    await _pumpRecord(tester, o);

    // The crop slot IS the record region selector; annotation tools are hidden.
    expect(find.byTooltip('Record'), findsOneWidget);
    expect(find.byTooltip('Rectangle'), findsNothing);
    // The three one-shot override toggles (cursor / system audio / mic).
    expect(find.byIcon(Icons.mouse), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    // HUD toggles do not show in record mode.
    expect(find.byIcon(Icons.gps_fixed), findsNothing);
    expect(find.byIcon(Icons.search), findsNothing);
    // The option row hosts the per-take codec + frame-rate pickers.
    expect(find.byKey(const ValueKey('record-format-picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('record-fps-picker')), findsOneWidget);
    // The record caption names the mode.
    expect(find.text('Record mode: the selection starts a recording'),
        findsOneWidget);
  });

  testWidgets('a record override toggle mutates only that override notifier',
      (tester) async {
    final o = _overrides();
    addTearDown(o.dispose);
    await _pumpRecord(tester, o);
    expect(o.showCursor.value, isTrue);
    await tester.tap(find.byIcon(Icons.mouse));
    await tester.pump();
    expect(o.showCursor.value, isFalse);
  });

  testWidgets('record mode: GIF greys out the audio override toggles',
      (tester) async {
    final o = _overrides(gif: true);
    addTearDown(o.dispose);
    await _pumpRecord(tester, o);
    final sysBtn = find.widgetWithIcon(IconButton, Icons.volume_up);
    expect(tester.widget<IconButton>(sysBtn).onPressed, isNull);
    final op = tester.widget<Opacity>(
      find.ancestor(of: sysBtn, matching: find.byType(Opacity)).first,
    );
    expect(op.opacity, 0.35);
  });

  testWidgets('the record codec pill opens the codec popover and applies a pick',
      (tester) async {
    final o = _overrides();
    addTearDown(o.dispose);
    await _pumpRecord(tester, o);
    await tester.tap(find.byKey(const ValueKey('record-format-picker')));
    await tester.pump();
    expect(find.byType(ChoiceListPopover<String>), findsOneWidget);
    // Pick HEVC (HDR): it rides the HEVC codec with the HDR flag on top.
    await tester.tap(find.text('HEVC (HDR)'));
    await tester.pump();
    expect(o.hevc.value, isTrue);
    expect(o.hdr.value, isTrue);
    expect(o.gif.value, isFalse);
  });
}
