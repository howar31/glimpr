import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_app.dart';
import 'package:glimpr/settings/settings_store.dart';
import 'package:glimpr/shortcuts/widgets/hotkey_recorder_field.dart';
import 'package:glimpr/shortcuts/widgets/key_cap_chips.dart';

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

void main() {
  testWidgets('captureArea row shows the default ⌘⌥1 binding', (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    expect(find.text('Capture'), findsOneWidget);
    // Default ⌘⌥1 renders three key caps (two modifiers + the digit). The
    // modifier glyphs are platform-dependent; the digit '1' is not, so assert on
    // it (and on the cap count) for a host-platform-stable check.
    expect(find.widgetWithText(KeyCap, '1'), findsOneWidget);
    expect(find.byType(KeyCap), findsNWidgets(3));
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
    await tester.tap(find.byType(HotkeyRecorderField));
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
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    // Now dirty + valid: both buttons show and Apply is the live accent button.
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Revert'), findsOneWidget);
    expect(find.widgetWithText(KeyCap, 'G'), findsOneWidget);
  });

  testWidgets('per-row Reset restores the default + clears the dirty state',
      (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // Change to ⌘G first.
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();
    expect(find.text('Apply'), findsOneWidget);

    // Reset the row back to the ⌘⌥1 default.
    await tester.tap(find.byTooltip('Reset to default'));
    await tester.pumpAndSettle();

    // Back to default => clean => Apply hidden, ⌘⌥1 shown again (two modifiers
    // + the digit '1').
    expect(find.text('Apply'), findsNothing);
    expect(find.widgetWithText(KeyCap, '1'), findsOneWidget);
    expect(find.byType(KeyCap), findsNWidgets(3));
  });

  testWidgets('clearing during recording disables the global hotkey',
      (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // Clear is reachable through recording: click the field, then the in-field ✕.
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();

    // Unbound => muted "Disabled" text (NOT a pressable cap); null is valid for a
    // global binding (= disabled), so the draft is dirty + valid and Apply shows.
    expect(find.byType(KeyCap), findsNothing);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
  });

  testWidgets('clicking Reset while recording cancels record + shows new value',
      (tester) async {
    final settings = Settings(FakeStore());
    await _openShortcuts(tester, settings);

    // Bind ⌘G first so the later Reset is a real value change (⌘G -> ⌘⌥1).
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    // Re-enter recording, then click Reset (↻) mid-record.
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    expect(find.text('Press keys…'), findsOneWidget);
    await tester.tap(find.byTooltip('Reset to default'));
    await tester.pumpAndSettle();

    // Recording is cancelled and the default ⌘⌥1 is shown again.
    expect(find.text('Press keys…'), findsNothing);
    expect(find.widgetWithText(KeyCap, '1'), findsOneWidget);
  });
}
