import 'package:flutter/services.dart';
import 'hotkey_binding.dart';
import 'hotkey_registrar.dart';
import 'register_result.dart';
import 'windows_hotkey_codes.dart';

/// Windows registrar over native Win32 RegisterHotKey (`glimpr/hotkeys` channel).
/// RegisterHotKey is system-global; a successful native registration returns
/// [RegisterResult.ok], a failure (e.g. ERROR_HOTKEY_ALREADY_REGISTERED) or an
/// unmappable key returns [UnavailableReason.error]. The shared channel plumbing
/// (onHotkey dispatch, register skeleton, fallback) lives in
/// [ChannelHotkeyRegistrar]; this adds the Win32 payload and the recorder's
/// native key-capture session.
class WindowsHotkeyRegistrar extends ChannelHotkeyRegistrar
    implements HotkeyKeyCapture {
  WindowsHotkeyRegistrar([super.channel]);

  // Active recorder capture session (only one field records at a time).
  void Function(int vk, int modifierMask, bool available)? _onCaptureKey;
  void Function()? _onCaptureCancel;

  @override
  Future<dynamic> onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onCaptureKey':
        final a = (call.arguments as Map).cast<String, dynamic>();
        _onCaptureKey?.call(
            a['vk'] as int, a['modifiers'] as int, a['available'] as bool? ?? true);
      case 'onCaptureCancel':
        _onCaptureCancel?.call();
      default:
        return super.onNativeCall(call);
    }
    return null;
  }

  @override
  Future<void> beginKeyCapture(
    void Function(int vk, int modifierMask, bool available) onKey,
    void Function() onCancel,
  ) async {
    _onCaptureKey = onKey;
    _onCaptureCancel = onCancel;
    await channel.invokeMethod('beginCaptureKeys');
  }

  @override
  Future<void> endKeyCapture() async {
    _onCaptureKey = null;
    _onCaptureCancel = null;
    await channel.invokeMethod('endCaptureKeys');
  }

  @override
  Map<String, Object?>? registerArgs(HotkeyBinding binding) {
    final vk = win32VirtualKey(binding.physicalKey);
    if (vk == null) return null;
    return {
      'vk': vk,
      'modifiers': win32ModifierMask(binding.modifiers),
      // Full accelerator hint for the native tray menu, e.g. "Ctrl+Alt+Win+1".
      'keyLabel': binding.label(TargetPlatform.windows),
    };
  }
}
