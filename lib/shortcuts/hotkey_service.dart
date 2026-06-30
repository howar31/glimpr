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

  // Actions whose stored binding could NOT be registered at [start] — the combo
  // is reserved by the OS / already taken by another app. main() warns the user
  // once at boot (ShareX-style); Settings seeds its inline markers from this.
  final Set<String> _failed = {};
  Set<String> get failedActions => Set.unmodifiable(_failed);

  /// Registers all global actions. Null bindings are skipped (disabled). Never
  /// throws — a registration failure is logged so it cannot block app start.
  Future<void> start() async {
    try {
      await registrar.unregisterAll();
      _failed.clear();
      for (final a in kGlobalActions) {
        final b = _bindings.containsKey(a.actionKey)
            ? _bindings[a.actionKey]
            : defaultBindingFor(a.actionKey);
        if (b == null) continue; // disabled
        final r =
            await registrar.register(a.actionKey, b, () => onAction(a.actionKey));
        if (r is RegisterUnavailable) _failed.add(a.actionKey);
      }
    } catch (e, st) {
      debugPrint('HotkeyService.start failed: $e\n$st');
    }
  }

  /// Temporarily unregister ALL global hotkeys (so the Settings recorder can
  /// capture a system-registered combo instead of the OS firing its action).
  /// Never throws. Restore with [resumeAll].
  Future<void> pauseAll() async {
    try {
      await registrar.unregisterAll();
    } catch (e, st) {
      debugPrint('HotkeyService.pauseAll failed: $e\n$st');
    }
  }

  /// Re-register everything from the current bindings after a [pauseAll].
  Future<void> resumeAll() => start();

  /// Live re-register of one action (no restart). Null = disable.
  Future<RegisterResult> rebind(String actionKey, HotkeyBinding? binding) async {
    _bindings[actionKey] = binding;
    await registrar.unregister(actionKey);
    if (binding == null) return const RegisterResult.ok();
    return registrar.register(actionKey, binding, () => onAction(actionKey));
  }
}
