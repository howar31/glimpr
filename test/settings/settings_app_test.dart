import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_app.dart';
import 'package:glimpr/settings/settings_store.dart';

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

void main() {
  testWidgets('shows the default hint when no folder is set', (tester) async {
    final settings = Settings(FakeStore());
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    // The save folder moved to the Output pane.
    await tester.tap(find.text('Output'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Default'), findsOneWidget);
  });

  testWidgets('shows the stored folder when one is set', (tester) async {
    final settings = Settings(FakeStore());
    await settings.setSaveDirectory('/tmp/shots');
    // A fresh mount models opening the settings window with the stored value.
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Output'));
    await tester.pumpAndSettle();
    // The wider save-folder line splits the path into an ellipsizing head and a
    // pinned trailing segment, so the full string is no longer one Text widget.
    // Assert on the visible trailing folder; the full path lives in the Tooltip.
    expect(find.textContaining('shots'), findsOneWidget);
    expect(find.byTooltip('/tmp/shots'), findsOneWidget);
  });

  testWidgets('General pane has the language picker', (tester) async {
    final settings = Settings(FakeStore());
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    // General is the default pane.
    expect(find.text('Language'), findsOneWidget);
    await tester.tap(find.text('繁體中文'));
    await tester.pumpAndSettle();
    expect(await settings.getAppLanguage(), 'zh');
    // Changing from the launch value shows the restart hint.
    expect(find.text('Restart Glimpr for this to take effect.'),
        findsOneWidget);
  });

  testWidgets('Advanced pane has the capture layers setting', (tester) async {
    // Tall surface so the whole Advanced pane builds (the layers card sits
    // below the multi-display card, off-screen at the default test size).
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = Settings(FakeStore());
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Capture layers'), findsOneWidget);
    // Picking 3 persists (the warm-engines Segmented also renders a '3', so
    // target the LAST one: the layers row sits below the engines row).
    await tester.tap(find.text('3').last);
    await tester.pumpAndSettle();
    expect(await settings.getCaptureLayerCap(), 3);
  });
}
