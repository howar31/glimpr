import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_app.dart';
import 'package:glimpr/settings/settings_store.dart';
import 'package:glimpr/shortcuts/widgets/hotkey_recorder_field.dart';
import 'package:glimpr/shortcuts/widgets/key_cap_chips.dart';
import 'package:glimpr/theme/glimpr_controls.dart';

class FakeStore implements SettingsStore {
  final Map<String, Object> _m = {};
  @override
  Future<String?> getString(String key) async => _m[key] as String?;
  @override
  Future<void> setString(String key, String value) async => _m[key] = value;
  @override
  Future<bool?> getBool(String key) async => _m[key] as bool?;
  @override
  Future<void> setBool(String key, bool value) async => _m[key] = value;
  @override
  Future<int?> getInt(String key) async => _m[key] as int?;
  @override
  Future<void> setInt(String key, int value) async => _m[key] = value;
  @override
  Future<void> remove(String key) async => _m.remove(key);
}

// Opens the Shortcuts pane in a freshly pumped SettingsApp.
Future<void> _openShortcuts(WidgetTester tester, Settings settings) async {
  await tester.pumpWidget(SettingsApp(settings: settings));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Shortcuts'));
  await tester.pumpAndSettle();
}

// The Global section is the first GlassCard in the pane; the Editor section
// (added in Phase 4.1b) is the second. These finders scope the global-row
// assertions to that first card so the editor rows below it don't make
// type-based finds (HotkeyRecorderField / KeyCap / 'Reset to default') ambiguous.
final _globalCard = find.byType(GlassCard).first;
Finder _inGlobal(Finder matching) =>
    find.descendant(of: _globalCard, matching: matching);
// The global card now has 4 rows (captureArea + the 3 Phase-4 modes). Tests
// that probe the interaction mechanics only need one representative row; we
// target the first one (captureArea / ⌘⌥1) so they remain stable as new
// global actions are added.
final _globalRecorder = _inGlobal(find.byType(HotkeyRecorderField)).first;

// The Editor section now sits between the Global card and the Apply/Revert
// footer, pushing the footer below the test viewport. Scroll it back into view
// before asserting on the Apply/Revert buttons.
Future<void> _scrollToFooter(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byType(GhostButton),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('captureArea row shows the default ⌘⌥1 binding', (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    expect(find.text('Capture'), findsOneWidget);
    // Default ⌘⌥1 renders three key caps (two modifiers + the digit). The
    // modifier glyphs are platform-dependent; the digit '1' is not, so assert on
    // it for a host-platform-stable check. Scope to the Global card: the Editor
    // section also has a bare '1' (the Rectangle tool).
    expect(_inGlobal(find.widgetWithText(KeyCap, '1')), findsOneWidget);
    // The global card now has 6 rows (captureArea + 3 Phase-4 modes + 2 open-
    // editor actions), each with 3 caps (⌘⌥ modifier pair + one digit) = 18.
    expect(_inGlobal(find.byType(KeyCap)), findsNWidgets(18));
  });

  testWidgets('Tools / Commands / Reserved sections render their rows',
      (tester) async {
    // The three editor cards are taller than the default 600px test viewport
    // (a lazy ListView would leave the lower sections unbuilt); enlarge the
    // surface so the whole pane renders for the structural assertions.
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // The editor shortcuts are split into three labelled cards below the Capture
    // card. SectionLabel uppercases its text. Tool rows (e.g. Crop) live under
    // TOOLS, command rows (e.g. Undo) under COMMANDS, and the reserved fixed
    // keys (e.g. Cancel / Exit, Commit text) under RESERVED.
    expect(find.text('TOOLS'), findsOneWidget);
    expect(find.text('COMMANDS'), findsOneWidget);
    expect(find.text('RESERVED'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('Crop'), findsOneWidget);
    expect(find.text('Cancel / Exit'), findsOneWidget);
    expect(find.text('Commit text'), findsOneWidget);
    // Command-row hints (the ones we added explanations for).
    expect(find.text('From the clipboard'), findsOneWidget);
    expect(find.text('Remove the selected annotation'), findsOneWidget);
    expect(
      find.text('Screenshot the snapped window, or the whole screen'),
      findsOneWidget,
    );
    // 'esc' is a plain KeyCap (reserved, not a recorder). It appears in two
    // reserved rows: Cancel / Exit and Cancel text.
    expect(find.widgetWithText(KeyCap, 'esc'), findsNWidgets(2));
  });

  testWidgets('Apply / Revert are hidden until the draft is dirty',
      (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    expect(find.text('Apply'), findsNothing);
    expect(find.text('Revert'), findsNothing);
  });

  testWidgets(
      'recording a bare global key keeps Apply disabled with a modifier warning',
      (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // Record a bare 'G' on the global capture row (requireModifier => rejected).
    await tester.tap(_globalRecorder);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();

    // The recorder itself rejects a bare global key (requireModifier), so the
    // binding is unchanged and the draft stays clean — Apply never appears.
    expect(find.text('Apply'), findsNothing);
    expect(find.textContaining('modifier'), findsWidgets);
  });

  testWidgets('recording a valid combo enables Apply', (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // Record ⌘G on the global capture row.
    await tester.tap(_globalRecorder);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    // The ⌘G cap is on the (now-scrolled-into-view) global row.
    expect(_inGlobal(find.widgetWithText(KeyCap, 'G')), findsOneWidget);

    // Now dirty + valid: both buttons show and Apply is the live accent button.
    await _scrollToFooter(tester);
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Revert'), findsOneWidget);
  });

  testWidgets('per-row Reset is suppressed while a row is at its default',
      (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // Fresh draft: every row is at its default, so the Reset button is disabled
    // and its tooltip is suppressed everywhere (global + editor rows alike).
    expect(find.byTooltip('Reset to default'), findsNothing);
    // Each Reset IconButton is dimmed to 0.25 opacity at default. The global
    // card has 4 binding rows; target the first one (captureArea) specifically.
    final globalResetOpacity = _inGlobal(
      find.ancestor(
        of: find.byIcon(Icons.restart_alt),
        matching: find.byType(Opacity),
      ),
    ).first;
    expect(tester.widget<Opacity>(globalResetOpacity).opacity, 0.25);

    // Record ⌘G on the global capture row => it is now off-default.
    await tester.tap(_globalRecorder);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    // The tooltip reappears for exactly that one (now-dirty) row; the untouched
    // editor rows keep their suppressed tooltip.
    expect(find.byTooltip('Reset to default'), findsOneWidget);
    expect(_inGlobal(find.byTooltip('Reset to default')), findsOneWidget);
    // …and that row's Reset button is now at full opacity.
    expect(tester.widget<Opacity>(globalResetOpacity).opacity, 1.0);
  });

  testWidgets('per-row Reset restores the default + clears the dirty state',
      (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // Change to ⌘G first.
    await tester.tap(_globalRecorder);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();
    await _scrollToFooter(tester);
    expect(find.text('Apply'), findsOneWidget);

    // Reset the global row back to the ⌘⌥1 default (each editor row also has a
    // Reset button, so scope to the global card). The global row scrolled out of
    // view to reach the footer, so jump back to the top first (a large positive
    // drag) — scrollUntilVisible can't target the global card by a dynamic
    // descendant finder once it has been unmounted.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.tap(_inGlobal(find.byTooltip('Reset to default')));
    await tester.pumpAndSettle();

    // Back to default => clean => Apply hidden (footer is empty), ⌘⌥1 shown again
    // (two modifiers + the digit '1'; all 6 global rows back to their defaults).
    expect(find.text('Apply'), findsNothing);
    expect(_inGlobal(find.widgetWithText(KeyCap, '1')), findsOneWidget);
    expect(_inGlobal(find.byType(KeyCap)), findsNWidgets(18));
  });

  testWidgets('clearing during recording disables the global hotkey',
      (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // Clear is reachable through recording: click the field, then the in-field ✕.
    await tester.tap(_globalRecorder);
    await tester.pump();
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();

    // Unbound => muted "Disabled" text (NOT a pressable cap); null is valid for a
    // global binding (= disabled), so the draft is dirty + valid and Apply shows.
    // The other 3 global rows still have their default caps; only the cleared row
    // (captureArea) shows "Disabled". Find the recorder widget itself and check
    // that no KeyCap lives inside its parent row.
    expect(find.text('Disabled'), findsOneWidget);
    // The cleared recorder field contains no KeyCap (confirmed by no '1' digit cap).
    expect(_inGlobal(find.widgetWithText(KeyCap, '1')), findsNothing);
    // Apply lives in the footer below the Editor section — scroll it into view.
    await _scrollToFooter(tester);
    expect(find.text('Apply'), findsOneWidget);
  });

  testWidgets('clicking Reset while recording cancels record + shows new value',
      (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // Bind ⌘G first so the later Reset is a real value change (⌘G -> ⌘⌥1).
    await tester.tap(_globalRecorder);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    // Re-enter recording, then click Reset (↻) mid-record.
    await tester.tap(_globalRecorder);
    await tester.pump();
    expect(find.text('Press keys…'), findsOneWidget);
    await tester.tap(_inGlobal(find.byTooltip('Reset to default')));
    await tester.pumpAndSettle();

    // Recording is cancelled and the default ⌘⌥1 is shown again.
    expect(find.text('Press keys…'), findsNothing);
    expect(_inGlobal(find.widgetWithText(KeyCap, '1')), findsOneWidget);
  });
}
