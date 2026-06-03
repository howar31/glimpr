import 'dart:convert';
import '../settings/settings_store.dart';
import 'hotkey_binding.dart';
import 'shortcut_actions.dart';

const _kKey = 'shortcut_bindings';

/// Persists the map { actionKey: HotkeyBinding | null } as one JSON string.
/// A null value = explicitly unbound (distinct from "absent" = use default).
class ShortcutStore {
  ShortcutStore(this.store);
  final SettingsStore store;

  /// Parsed map of action -> (binding or null). Absent keys are not present.
  Future<Map<String, HotkeyBinding?>> _raw() async {
    final s = await store.getString(_kKey);
    if (s == null || s.isEmpty) return {};
    late final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return {}; // corrupt -> treat as all-default
    }
    final out = <String, HotkeyBinding?>{};
    for (final entry in decoded.entries) {
      final v = entry.value;
      out[entry.key] =
          v == null ? null : HotkeyBinding.fromJson(v as Map<String, dynamic>);
      // fromJson returning null for a non-null v means corrupt -> treat absent
      if (v != null && out[entry.key] == null) out.remove(entry.key);
    }
    return out;
  }

  /// The effective binding for an action: stored value, else the factory
  /// default. Returns null only if the user explicitly unbound it.
  Future<HotkeyBinding?> bindingFor(String actionKey) async {
    final raw = await _raw();
    if (raw.containsKey(actionKey)) return raw[actionKey];
    return kDefaultBindings[actionKey];
  }

  /// Like bindingFor but does NOT fall back to default — used by tests/UI to
  /// distinguish "unbound (null)" from "default".
  Future<HotkeyBinding?> bindingForRaw(String actionKey) async =>
      (await _raw())[actionKey];

  /// Every action's effective binding (defaults merged with stored overrides).
  Future<Map<String, HotkeyBinding?>> all() async {
    final raw = await _raw();
    final out = <String, HotkeyBinding?>{...kDefaultBindings};
    out.addAll(raw); // overrides (incl. explicit nulls)
    return out;
  }

  Future<void> saveAll(Map<String, HotkeyBinding?> bindings) async {
    final encoded = <String, dynamic>{};
    bindings.forEach((k, v) => encoded[k] = v?.toJson());
    await store.setString(_kKey, jsonEncode(encoded));
  }
}

/// Returns the action keys that collide (two+ share the same non-null binding).
Set<String> duplicateActionKeys(Map<String, HotkeyBinding?> bindings) {
  final seen = <HotkeyBinding, List<String>>{};
  bindings.forEach((k, v) {
    if (v == null) return;
    seen.putIfAbsent(v, () => []).add(k);
  });
  return seen.values.where((ks) => ks.length > 1).expand((ks) => ks).toSet();
}
