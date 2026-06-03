import 'package:flutter/foundation.dart';
import 'hotkey_binding.dart';
import 'hotkey_registrar.dart';
import 'register_result.dart';
import 'shortcut_actions.dart';

/// Owns Tier-1 (global) hotkey registration in the control engine. Construct
/// with the current bindings (effective: defaults merged with stored overrides)
/// and a callback that dispatches a fired actionKey to its handler.
class HotkeyService {
  HotkeyService({
    required this.registrar,
    required Map<String, HotkeyBinding?> bindings,
    required this.onAction,
  }) : _bindings = {...bindings};

  final HotkeyRegistrar registrar;
  final void Function(String actionKey) onAction;
  final Map<String, HotkeyBinding?> _bindings;

  /// Registers all global actions. Null bindings are skipped (disabled). Never
  /// throws — a registration failure is logged so it cannot block app start.
  Future<void> start() async {
    try {
      await registrar.unregisterAll();
      for (final a in kGlobalActions) {
        final b = _bindings.containsKey(a.actionKey)
            ? _bindings[a.actionKey]
            : kDefaultBindings[a.actionKey];
        if (b == null) continue; // disabled
        await registrar.register(a.actionKey, b, () => onAction(a.actionKey));
      }
    } catch (e, st) {
      debugPrint('HotkeyService.start failed: $e\n$st');
    }
  }

  /// Live re-register of one action (no restart). Null = disable.
  Future<RegisterResult> rebind(String actionKey, HotkeyBinding? binding) async {
    _bindings[actionKey] = binding;
    await registrar.unregister(actionKey);
    if (binding == null) return const RegisterResult.ok();
    return registrar.register(actionKey, binding, () => onAction(actionKey));
  }
}
