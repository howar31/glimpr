import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_app.dart';
import 'package:glimpr/settings/settings_store.dart';

class FakeStore implements SettingsStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> getString(String key) async => _m[key];
  @override
  Future<void> setString(String key, String value) async => _m[key] = value;
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
    expect(find.text('/tmp/shots'), findsOneWidget);
  });
}
