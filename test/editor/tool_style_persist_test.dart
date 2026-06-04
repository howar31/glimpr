import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';
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
  test('a style edited through the controller persists and re-seeds', () async {
    final store = ToolStyleStore(_MemStore());

    final map = await store.load();
    final c = EditorController(toolStyles: map);
    c.selectTool(ToolKind.rectangle);
    c.setColor(const Color(0xFF00FF00));
    await store.save(c.toolStyles); // host persists on change
    c.dispose();

    final reloaded = await store.load();
    final c2 = EditorController(toolStyles: reloaded);
    c2.selectTool(ToolKind.rectangle);
    expect(c2.style.value.color, const Color(0xFF00FF00));
    c2.dispose();
  });
}
