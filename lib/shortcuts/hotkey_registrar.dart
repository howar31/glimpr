import 'package:flutter/foundation.dart';
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

/// Shared `glimpr/hotkeys` channel plumbing for the two native registrars:
/// the action->callback map, the onHotkey dispatch (with [fallback]), the
/// register skeleton (map the key, store the callback, roll back on a native
/// refusal), and unregister/unregisterAll. Subclasses provide the platform
/// 'register' payload via [registerArgs] and may extend [onNativeCall] for
/// extra channel methods.
abstract class ChannelHotkeyRegistrar implements HotkeyRegistrar {
  ChannelHotkeyRegistrar([MethodChannel? channel])
      : channel = channel ?? const MethodChannel('glimpr/hotkeys') {
    this.channel.setMethodCallHandler(onNativeCall);
  }

  @protected
  final MethodChannel channel;
  final _byAction = <String, void Function()>{};

  /// Catch-all for actions fired natively (a menu item) that have NO
  /// registered hotkey callback (the user unbound the shortcut) — the menu
  /// item must still work. Set by main()'s control-engine bootstrap.
  void Function(String actionKey)? fallback;

  /// The platform-specific 'register' payload for [binding] (merged with the
  /// action id), or null when the key has no native mapping.
  @protected
  Map<String, Object?>? registerArgs(HotkeyBinding binding);

  @protected
  @mustCallSuper
  Future<dynamic> onNativeCall(MethodCall call) async {
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
    final args = registerArgs(binding);
    if (args == null) {
      return const RegisterResult.unavailable(UnavailableReason.error);
    }
    _byAction[actionKey] = onTrigger;
    final ok = await channel
        .invokeMethod<bool>('register', {'id': actionKey, ...args});
    if (ok == true) return const RegisterResult.ok();
    _byAction.remove(actionKey);
    return const RegisterResult.unavailable(UnavailableReason.error);
  }

  @override
  Future<void> unregister(String actionKey) async {
    _byAction.remove(actionKey);
    await channel.invokeMethod('unregister', {'id': actionKey});
  }

  @override
  Future<void> unregisterAll() async {
    _byAction.clear();
    await channel.invokeMethod('unregisterAll');
  }
}

/// macOS registrar over native Carbon (`glimpr/hotkeys` channel). Carbon
/// RegisterEventHotKey is non-exclusive and cannot find a third-party owner, so
/// a successful native registration returns [RegisterResult.ok]; an unmappable
/// key or a native failure returns [UnavailableReason.error]. The native side
/// fires `onHotkey(actionKey)`, dispatched to the stored callback.
class NativeHotkeyRegistrar extends ChannelHotkeyRegistrar {
  NativeHotkeyRegistrar([super.channel]);

  @override
  Map<String, Object?>? registerArgs(HotkeyBinding binding) {
    final keyCode = macOSKeyCode(binding.physicalKey);
    if (keyCode == null) return null;
    final label = binding.logicalKey.keyLabel;
    return {
      'keyCode': keyCode,
      'modifiers': carbonModifierMask(binding.modifiers),
      // Menu key-equivalent hint: a one-character key shows ⌘⌥7-style hints
      // on the menu-bar items; anything else shows no hint.
      'keyChar': label.length == 1 ? label.toLowerCase() : '',
      'cocoaMods': cocoaModifierMask(binding.modifiers),
    };
  }
}
