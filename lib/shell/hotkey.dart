import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// The global capture hotkey. macOS default ⌘⌥1 (design §12; never ⌘⇧3/4/5,
/// and the Command modifier sidesteps the macOS 15 Option-only regression).
/// Registered only by the control engine, not the per-display overlay engines.
/// Phase 4 makes this rebindable via HotKeyRecorder + persisted settings.
class CaptureHotkey {
  static final HotKey _hotKey = HotKey(
    key: PhysicalKeyboardKey.digit1,
    modifiers: [HotKeyModifier.meta, HotKeyModifier.alt],
    scope: HotKeyScope.system,
  );

  /// Registers the system-wide hotkey; [onTrigger] fires on key-down. Safe to
  /// call once at startup; clears any prior registration first.
  static Future<void> register(void Function() onTrigger) async {
    await hotKeyManager.unregisterAll();
    await hotKeyManager.register(_hotKey, keyDownHandler: (_) => onTrigger());
  }
}
