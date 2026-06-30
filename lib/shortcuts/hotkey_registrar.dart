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

/// Optional capability: native recorder key capture. Implemented only where
/// Flutter cannot deliver the keys to the recorder — Windows (it drops
/// PrintScreen + the Win key), via window-proc interception. macOS reads Flutter
/// key events directly and does NOT implement this. The recorder field checks
/// `registrar is HotkeyKeyCapture` and falls back to Flutter events otherwise.
abstract interface class HotkeyKeyCapture {
  /// Begin a capture session: [onKey] receives a Win32 virtual-key code, a
  /// RegisterHotKey-style modifier mask, and whether the combo is currently
  /// available (a record-time probe — false = reserved / already taken by
  /// another app). [onCancel] fires on Escape.
  Future<void> beginKeyCapture(
    void Function(int vk, int modifierMask, bool available) onKey,
    void Function() onCancel,
  );
  Future<void> endKeyCapture();
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

  /// Catch-all for actions fired natively (a menu-bar item) that have NO
  /// registered hotkey callback (the user unbound the shortcut) — the menu
  /// item must still work. Set by main()'s control-engine bootstrap.
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
    final keyCode = macOSKeyCode(binding.physicalKey);
    if (keyCode == null) {
      return const RegisterResult.unavailable(UnavailableReason.error);
    }
    _byAction[actionKey] = onTrigger;
    final label = binding.logicalKey.keyLabel;
    final ok = await _channel.invokeMethod<bool>('register', {
      'id': actionKey,
      'keyCode': keyCode,
      'modifiers': carbonModifierMask(binding.modifiers),
      // Menu key-equivalent hint: a one-character key shows ⌘⌥7-style hints
      // on the menu-bar items; anything else shows no hint.
      'keyChar': label.length == 1 ? label.toLowerCase() : '',
      'cocoaMods': cocoaModifierMask(binding.modifiers),
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
