import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/tool_style_store.dart';
import 'package:glimpr/settings/settings_store.dart';

class _MemStore implements SettingsStore {
  final _m = <String, Object>{};
  @override Future<String?> getString(String k) async => _m[k] as String?;
  @override Future<void> setString(String k, String v) async => _m[k] = v;
  @override Future<bool?> getBool(String k) async => _m[k] as bool?;
  @override Future<void> setBool(String k, bool v) async => _m[k] = v;
  @override Future<int?> getInt(String k) async => _m[k] as int?;
  @override Future<void> setInt(String k, int v) async => _m[k] = v;
  @override Future<void> remove(String k) async => _m.remove(k);
}

void main() {
  test('resetAll empties a populated store', () async {
    final store = _MemStore();
    await store.setString('tool_styles', '{"arrow":{"color":1,"strokeWidth":2.0,"fontSize":3.0}}');
    await ToolStyleStore(store).resetAll();
    expect(await store.getString('tool_styles'), isNull);
  });
}
