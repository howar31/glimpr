import 'package:hotkey_manager/hotkey_manager.dart';
import 'hotkey_binding.dart';
import 'register_result.dart';

/// Platform seam for global-hotkey registration. macOS wraps hotkey_manager;
/// Windows (Phase 6) implements this with Win32 RegisterHotKey and returns
/// RegisterResult.unavailable(alreadyInUse) on ERROR_HOTKEY_ALREADY_REGISTERED.
abstract class HotkeyRegistrar {
  Future<RegisterResult> register(
    String actionKey,
    HotkeyBinding binding,
    void Function() onTrigger,
  );
  Future<void> unregister(String actionKey);
  Future<void> unregisterAll();
}

/// macOS registrar. hotkey_manager registration is non-exclusive and cannot
/// detect conflicts, so this always returns RegisterResult.ok (or rethrows —
/// HotkeyService wraps start() in try/catch). Tracks HotKey per actionKey so a
/// rebind unregisters only that action.
class HotkeyManagerRegistrar implements HotkeyRegistrar {
  final _byAction = <String, HotKey>{};

  @override
  Future<RegisterResult> register(
    String actionKey,
    HotkeyBinding binding,
    void Function() onTrigger,
  ) async {
    final hotKey = binding.toHotKey();
    _byAction[actionKey] = hotKey;
    await hotKeyManager.register(hotKey, keyDownHandler: (_) => onTrigger());
    return const RegisterResult.ok();
  }

  @override
  Future<void> unregister(String actionKey) async {
    final hotKey = _byAction.remove(actionKey);
    if (hotKey != null) await hotKeyManager.unregister(hotKey);
  }

  @override
  Future<void> unregisterAll() async {
    _byAction.clear();
    await hotKeyManager.unregisterAll();
  }
}
