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
    expect(find.textContaining('Default'), findsOneWidget);
  });

  testWidgets('shows the stored folder when one is set', (tester) async {
    final settings = Settings(FakeStore());
    await settings.setSaveDirectory('/tmp/shots');
    // A fresh mount models opening the settings window with the stored value.
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    // The wider save-folder line splits the path into an ellipsizing head and a
    // pinned trailing segment, so the full string is no longer one Text widget.
    // Assert on the visible trailing folder; the full path lives in the Tooltip.
    expect(find.textContaining('shots'), findsOneWidget);
    expect(find.byTooltip('/tmp/shots'), findsOneWidget);
  });
}
