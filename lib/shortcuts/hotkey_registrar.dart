import 'package:flutter/services.dart';
import 'hotkey_binding.dart';
import 'macos_hotkey_codes.dart';
import 'register_result.dart';

/// Platform seam for global-hotkey registration. macOS uses a native Carbon
/// `RegisterEventHotKey` registrar; Windows (Phase 6) implements this with Win32
/// RegisterHotKey and returns RegisterResult.unavailable(alreadyInUse) on
/// ERROR_HOTKEY_ALREADY_REGISTERED.
abstract class HotkeyRegistrar {
  Future<RegisterResult> register(
    String actionKey,
    HotkeyBinding binding,
    void Function() onTrigger,
  );
  Future<void> unregister(String actionKey);
  Future<void> unregisterAll();
}

/// macOS registrar over native Carbon (`glimpr/hotkeys` channel). Carbon
/// RegisterEventHotKey is non-exclusive and cannot find a third-party owner, so
/// a successful native registration returns [RegisterResult.ok]; an unmappable
/// key or a native failure returns [UnavailableReason.error]. The native side
/// fires `onHotkey(actionKey)`, dispatched here to the stored callback.
class NativeHotkeyRegistrar implements HotkeyRegistrar {
  NativeHotkeyRegistrar([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel('glimpr/hotkeys') {
    _channel.setMethodCallHandler(_onNative);
  }

  final MethodChannel _channel;
  final _byAction = <String, void Function()>{};

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method == 'onHotkey') {
      _byAction[call.arguments as String]?.call();
    }
    return null;
  }

  @override
  Future<RegisterResult> register(
    String actionKey,
    HotkeyBinding binding,
    void Function() onTrigger,
  ) async {
    final keyCode = macOSKeyCode(binding.physicalKey);
    if (keyCode == null) {
      return const RegisterResult.unavailable(UnavailableReason.error);
    }
    _byAction[actionKey] = onTrigger;
    final ok = await _channel.invokeMethod<bool>('register', {
      'id': actionKey,
      'keyCode': keyCode,
      'modifiers': carbonModifierMask(binding.modifiers),
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
