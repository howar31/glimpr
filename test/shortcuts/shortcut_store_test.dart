import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings_store.dart';
import 'package:glimpr/shortcuts/shortcut_store.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:flutter/services.dart';

class _MemStore implements SettingsStore {
  final map = <String, Object?>{};
  @override
  Future<String?> getString(String k) async => map[k] as String?;
  @override
  Future<void> setString(String k, String v) async => map[k] = v;
  @override
  Future<bool?> getBool(String k) async => map[k] as bool?;
  @override
  Future<void> setBool(String k, bool v) async => map[k] = v;
  @override
  Future<int?> getInt(String k) async => map[k] as int?;
  @override
  Future<void> setInt(String k, int v) async => map[k] = v;
  @override
  Future<void> remove(String k) async => map.remove(k);
}

void main() {
  test('returns defaults when unset', () async {
    final s = ShortcutStore(_MemStore());
    expect(
        await s.bindingFor(kCaptureAreaKey), kDefaultBindings[kCaptureAreaKey]);
  });

  test('saveAll then read back', () async {
    final store = _MemStore();
    final s = ShortcutStore(store);
    const custom = HotkeyBinding(
      physicalKey: PhysicalKeyboardKey.keyG,
      logicalKey: LogicalKeyboardKey.keyG,
      modifiers: {HotkeyModifier.meta, HotkeyModifier.shift},
    );
    await s.saveAll({kCaptureAreaKey: custom});
    expect(await s.bindingFor(kCaptureAreaKey), custom);
  });

  test('null (unbound) persists and reads back as null', () async {
    final store = _MemStore();
    final s = ShortcutStore(store);
    await s.saveAll({kCaptureAreaKey: null});
    expect(await s.bindingForRaw(kCaptureAreaKey), isNull);
  });

  test('corrupt JSON falls back to all defaults', () async {
    final store = _MemStore()..map['shortcut_bindings'] = '{not json';
    final s = ShortcutStore(store);
    expect(
        await s.bindingFor(kCaptureAreaKey), kDefaultBindings[kCaptureAreaKey]);
  });

  test('duplicate detection finds two editor actions on the same combo', () {
    const c = HotkeyBinding(
      physicalKey: PhysicalKeyboardKey.keyX,
      logicalKey: LogicalKeyboardKey.keyX,
      modifiers: {},
    );
    final dupes = duplicateActionKeys({'editor.crop': c, 'editor.blur': c});
    expect(dupes, containsAll(['editor.crop', 'editor.blur']));
  });
}
