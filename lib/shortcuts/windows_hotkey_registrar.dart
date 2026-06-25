import 'package:flutter/services.dart';
import 'hotkey_binding.dart';
import 'hotkey_registrar.dart';
import 'register_result.dart';
import 'windows_hotkey_codes.dart';

/// Windows registrar over native Win32 RegisterHotKey (`glimpr/hotkeys` channel).
/// RegisterHotKey is system-global; a successful native registration returns
/// [RegisterResult.ok], a failure (e.g. ERROR_HOTKEY_ALREADY_REGISTERED) or an
/// unmappable key returns [UnavailableReason.error]. The native side fires
/// `onHotkey(actionKey)`, dispatched here to the stored callback (or [fallback]
/// for a menu item whose action has no bound hotkey). Mirrors NativeHotkeyRegistrar.
class WindowsHotkeyRegistrar implements HotkeyRegistrar {
  WindowsHotkeyRegistrar([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel('glimpr/hotkeys') {
    _channel.setMethodCallHandler(_onNative);
  }

  final MethodChannel _channel;
  final _byAction = <String, void Function()>{};

  /// Catch-all for actions fired natively (a tray menu item) with NO registered
  /// hotkey callback (the shortcut is unbound). Set by main()'s bootstrap.
  void Function(String actionKey)? fallback;

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method == 'onHotkey') {
      final key = call.arguments as String;
      final cb = _byAction[key];
      if (cb != null) {
        cb();
      } else {
        fallback?.call(key);
      }
    }
    return null;
  }

  @override
  Future<RegisterResult> register(
    String actionKey,
    HotkeyBinding binding,
    void Function() onTrigger,
  ) async {
    final vk = win32VirtualKey(binding.physicalKey);
    if (vk == null) {
      return const RegisterResult.unavailable(UnavailableReason.error);
    }
    _byAction[actionKey] = onTrigger;
    final ok = await _channel.invokeMethod<bool>('register', {
      'id': actionKey,
      'vk': vk,
      'modifiers': win32ModifierMask(binding.modifiers),
      // Full accelerator hint for the native tray menu, e.g. "Ctrl+Alt+Win+1".
      'keyLabel': binding.label(TargetPlatform.windows),
    });
    if (ok == true) return const RegisterResult.ok();
    _byAction.remove(actionKey);
    return const RegisterResult.unavailable(UnavailableReason.error);
  }

  @override
  Future<void> unregister(String actionKey) async {
    _byAction.remove(actionKey);
    await _channel.invokeMethod('unregister', {'id': actionKey});
  }

  @override
  Future<void> unregisterAll() async {
    _byAction.clear();
    await _channel.invokeMethod('unregisterAll');
  }
}
