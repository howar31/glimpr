import 'package:flutter/services.dart';
import 'hotkey_binding.dart';

/// macOS-only: maps a layout-independent [PhysicalKeyboardKey] to its Carbon
/// virtual keycode (kVK_ANSI_* / kVK_* from `<Carbon/HIToolbox/Events.h>`), and a
/// [HotkeyModifier] set to the Carbon modifier mask. Used by the native Carbon
/// `RegisterEventHotKey` registrar. Windows gets its own (Win32) mapping.
///
/// Returns null for a key with no stable virtual keycode (e.g. Fn) — the
/// registrar then skips it (a global hotkey on such a key is not registrable).

// Non-const (PhysicalKeyboardKey overrides ==, so it can't key a const map).
final Map<PhysicalKeyboardKey, int> _kVirtualKeyCodes = {
  // Letters
  PhysicalKeyboardKey.keyA: 0x00,
  PhysicalKeyboardKey.keyS: 0x01,
  PhysicalKeyboardKey.keyD: 0x02,
  PhysicalKeyboardKey.keyF: 0x03,
  PhysicalKeyboardKey.keyH: 0x04,
  PhysicalKeyboardKey.keyG: 0x05,
  PhysicalKeyboardKey.keyZ: 0x06,
  PhysicalKeyboardKey.keyX: 0x07,
  PhysicalKeyboardKey.keyC: 0x08,
  PhysicalKeyboardKey.keyV: 0x09,
  PhysicalKeyboardKey.keyB: 0x0B,
  PhysicalKeyboardKey.keyQ: 0x0C,
  PhysicalKeyboardKey.keyW: 0x0D,
  PhysicalKeyboardKey.keyE: 0x0E,
  PhysicalKeyboardKey.keyR: 0x0F,
  PhysicalKeyboardKey.keyY: 0x10,
  PhysicalKeyboardKey.keyT: 0x11,
  PhysicalKeyboardKey.keyO: 0x1F,
  PhysicalKeyboardKey.keyU: 0x20,
  PhysicalKeyboardKey.keyI: 0x22,
  PhysicalKeyboardKey.keyP: 0x23,
  PhysicalKeyboardKey.keyL: 0x25,
  PhysicalKeyboardKey.keyJ: 0x26,
  PhysicalKeyboardKey.keyK: 0x28,
  PhysicalKeyboardKey.keyN: 0x2D,
  PhysicalKeyboardKey.keyM: 0x2E,
  // Digits
  PhysicalKeyboardKey.digit1: 0x12,
  PhysicalKeyboardKey.digit2: 0x13,
  PhysicalKeyboardKey.digit3: 0x14,
  PhysicalKeyboardKey.digit4: 0x15,
  PhysicalKeyboardKey.digit5: 0x17,
  PhysicalKeyboardKey.digit6: 0x16,
  PhysicalKeyboardKey.digit7: 0x1A,
  PhysicalKeyboardKey.digit8: 0x1C,
  PhysicalKeyboardKey.digit9: 0x19,
  PhysicalKeyboardKey.digit0: 0x1D,
  // Punctuation / symbols
  PhysicalKeyboardKey.equal: 0x18,
  PhysicalKeyboardKey.minus: 0x1B,
  PhysicalKeyboardKey.bracketRight: 0x1E,
  PhysicalKeyboardKey.bracketLeft: 0x21,
  PhysicalKeyboardKey.quote: 0x27,
  PhysicalKeyboardKey.semicolon: 0x29,
  PhysicalKeyboardKey.backslash: 0x2A,
  PhysicalKeyboardKey.comma: 0x2B,
  PhysicalKeyboardKey.slash: 0x2C,
  PhysicalKeyboardKey.period: 0x2F,
  PhysicalKeyboardKey.backquote: 0x32,
  // Whitespace / editing
  PhysicalKeyboardKey.enter: 0x24,
  PhysicalKeyboardKey.tab: 0x30,
  PhysicalKeyboardKey.space: 0x31,
  PhysicalKeyboardKey.backspace: 0x33,
  PhysicalKeyboardKey.delete: 0x75,
  PhysicalKeyboardKey.home: 0x73,
  PhysicalKeyboardKey.end: 0x77,
  PhysicalKeyboardKey.pageUp: 0x74,
  PhysicalKeyboardKey.pageDown: 0x79,
  // Arrows
  PhysicalKeyboardKey.arrowLeft: 0x7B,
  PhysicalKeyboardKey.arrowRight: 0x7C,
  PhysicalKeyboardKey.arrowDown: 0x7D,
  PhysicalKeyboardKey.arrowUp: 0x7E,
  // Function keys
  PhysicalKeyboardKey.f1: 0x7A,
  PhysicalKeyboardKey.f2: 0x78,
  PhysicalKeyboardKey.f3: 0x63,
  PhysicalKeyboardKey.f4: 0x76,
  PhysicalKeyboardKey.f5: 0x60,
  PhysicalKeyboardKey.f6: 0x61,
  PhysicalKeyboardKey.f7: 0x62,
  PhysicalKeyboardKey.f8: 0x64,
  PhysicalKeyboardKey.f9: 0x65,
  PhysicalKeyboardKey.f10: 0x6D,
  PhysicalKeyboardKey.f11: 0x67,
  PhysicalKeyboardKey.f12: 0x6F,
};

/// The Carbon virtual keycode for [key], or null when it has none.
int? macOSKeyCode(PhysicalKeyboardKey key) => _kVirtualKeyCodes[key];

// Carbon modifier mask bits (Events.h): cmdKey / shiftKey / optionKey / controlKey.
const int _cmdKey = 0x100;
const int _shiftKey = 0x200;
const int _optionKey = 0x800;
const int _controlKey = 0x1000;

/// The Carbon modifier mask for [modifiers], for RegisterEventHotKey.
int carbonModifierMask(Set<HotkeyModifier> modifiers) {
  var mask = 0;
  if (modifiers.contains(HotkeyModifier.meta)) mask |= _cmdKey;
  if (modifiers.contains(HotkeyModifier.shift)) mask |= _shiftKey;
  if (modifiers.contains(HotkeyModifier.alt)) mask |= _optionKey;
  if (modifiers.contains(HotkeyModifier.control)) mask |= _controlKey;
  return mask;
}

/// The Cocoa (NSEvent.ModifierFlags) mask for [modifiers] — used for the
/// menu-bar items' key-equivalent display hints.
int cocoaModifierMask(Set<HotkeyModifier> modifiers) {
  var mask = 0;
  if (modifiers.contains(HotkeyModifier.shift)) mask |= 1 << 17;
  if (modifiers.contains(HotkeyModifier.control)) mask |= 1 << 18;
  if (modifiers.contains(HotkeyModifier.alt)) mask |= 1 << 19;
  if (modifiers.contains(HotkeyModifier.meta)) mask |= 1 << 20;
  return mask;
}
