import 'package:flutter/services.dart';
import 'hotkey_binding.dart';

/// Windows-only: maps a layout-independent [PhysicalKeyboardKey] to its Win32
/// virtual-key code (VK_*), and a [HotkeyModifier] set to the Win32 RegisterHotKey
/// modifier mask (MOD_*). The macOS analogue is macos_hotkey_codes.dart (Carbon).
///
/// Returns null for a key with no stable virtual key (e.g. Fn) — the registrar
/// then skips it (a global hotkey on such a key is not registrable).

// Non-const (PhysicalKeyboardKey overrides ==, so it can't key a const map).
final Map<PhysicalKeyboardKey, int> _kWin32VirtualKeys = {
  // Letters 'A'-'Z' = 0x41-0x5A.
  PhysicalKeyboardKey.keyA: 0x41,
  PhysicalKeyboardKey.keyB: 0x42,
  PhysicalKeyboardKey.keyC: 0x43,
  PhysicalKeyboardKey.keyD: 0x44,
  PhysicalKeyboardKey.keyE: 0x45,
  PhysicalKeyboardKey.keyF: 0x46,
  PhysicalKeyboardKey.keyG: 0x47,
  PhysicalKeyboardKey.keyH: 0x48,
  PhysicalKeyboardKey.keyI: 0x49,
  PhysicalKeyboardKey.keyJ: 0x4A,
  PhysicalKeyboardKey.keyK: 0x4B,
  PhysicalKeyboardKey.keyL: 0x4C,
  PhysicalKeyboardKey.keyM: 0x4D,
  PhysicalKeyboardKey.keyN: 0x4E,
  PhysicalKeyboardKey.keyO: 0x4F,
  PhysicalKeyboardKey.keyP: 0x50,
  PhysicalKeyboardKey.keyQ: 0x51,
  PhysicalKeyboardKey.keyR: 0x52,
  PhysicalKeyboardKey.keyS: 0x53,
  PhysicalKeyboardKey.keyT: 0x54,
  PhysicalKeyboardKey.keyU: 0x55,
  PhysicalKeyboardKey.keyV: 0x56,
  PhysicalKeyboardKey.keyW: 0x57,
  PhysicalKeyboardKey.keyX: 0x58,
  PhysicalKeyboardKey.keyY: 0x59,
  PhysicalKeyboardKey.keyZ: 0x5A,
  // Digits '0'-'9' = 0x30-0x39.
  PhysicalKeyboardKey.digit0: 0x30,
  PhysicalKeyboardKey.digit1: 0x31,
  PhysicalKeyboardKey.digit2: 0x32,
  PhysicalKeyboardKey.digit3: 0x33,
  PhysicalKeyboardKey.digit4: 0x34,
  PhysicalKeyboardKey.digit5: 0x35,
  PhysicalKeyboardKey.digit6: 0x36,
  PhysicalKeyboardKey.digit7: 0x37,
  PhysicalKeyboardKey.digit8: 0x38,
  PhysicalKeyboardKey.digit9: 0x39,
  // Punctuation / OEM keys (US layout VK_OEM_*).
  PhysicalKeyboardKey.minus: 0xBD, // VK_OEM_MINUS
  PhysicalKeyboardKey.equal: 0xBB, // VK_OEM_PLUS
  PhysicalKeyboardKey.bracketLeft: 0xDB, // VK_OEM_4
  PhysicalKeyboardKey.bracketRight: 0xDD, // VK_OEM_6
  PhysicalKeyboardKey.backslash: 0xDC, // VK_OEM_5
  PhysicalKeyboardKey.semicolon: 0xBA, // VK_OEM_1
  PhysicalKeyboardKey.quote: 0xDE, // VK_OEM_7
  PhysicalKeyboardKey.backquote: 0xC0, // VK_OEM_3
  PhysicalKeyboardKey.comma: 0xBC, // VK_OEM_COMMA
  PhysicalKeyboardKey.period: 0xBE, // VK_OEM_PERIOD
  PhysicalKeyboardKey.slash: 0xBF, // VK_OEM_2
  // Whitespace / editing.
  PhysicalKeyboardKey.enter: 0x0D, // VK_RETURN
  PhysicalKeyboardKey.tab: 0x09, // VK_TAB
  PhysicalKeyboardKey.space: 0x20, // VK_SPACE
  PhysicalKeyboardKey.backspace: 0x08, // VK_BACK
  PhysicalKeyboardKey.delete: 0x2E, // VK_DELETE
  PhysicalKeyboardKey.home: 0x24, // VK_HOME
  PhysicalKeyboardKey.end: 0x23, // VK_END
  PhysicalKeyboardKey.pageUp: 0x21, // VK_PRIOR
  PhysicalKeyboardKey.pageDown: 0x22, // VK_NEXT
  // Arrows.
  PhysicalKeyboardKey.arrowLeft: 0x25, // VK_LEFT
  PhysicalKeyboardKey.arrowUp: 0x26, // VK_UP
  PhysicalKeyboardKey.arrowRight: 0x27, // VK_RIGHT
  PhysicalKeyboardKey.arrowDown: 0x28, // VK_DOWN
  // Function keys VK_F1..VK_F12 = 0x70..0x7B.
  PhysicalKeyboardKey.f1: 0x70,
  PhysicalKeyboardKey.f2: 0x71,
  PhysicalKeyboardKey.f3: 0x72,
  PhysicalKeyboardKey.f4: 0x73,
  PhysicalKeyboardKey.f5: 0x74,
  PhysicalKeyboardKey.f6: 0x75,
  PhysicalKeyboardKey.f7: 0x76,
  PhysicalKeyboardKey.f8: 0x77,
  PhysicalKeyboardKey.f9: 0x78,
  PhysicalKeyboardKey.f10: 0x79,
  PhysicalKeyboardKey.f11: 0x7A,
  PhysicalKeyboardKey.f12: 0x7B,
};

/// The Win32 virtual keycode for [key], or null when it has none.
int? win32VirtualKey(PhysicalKeyboardKey key) => _kWin32VirtualKeys[key];

// RegisterHotKey fsModifiers bits (winuser.h).
const int _modAlt = 0x0001; // MOD_ALT
const int _modControl = 0x0002; // MOD_CONTROL
const int _modShift = 0x0004; // MOD_SHIFT
const int _modWin = 0x0008; // MOD_WIN

/// The Win32 RegisterHotKey modifier mask for [modifiers] (MOD_NOREPEAT is added
/// natively, not here). meta -> MOD_WIN (the Windows key).
int win32ModifierMask(Set<HotkeyModifier> modifiers) {
  var mask = 0;
  if (modifiers.contains(HotkeyModifier.alt)) mask |= _modAlt;
  if (modifiers.contains(HotkeyModifier.control)) mask |= _modControl;
  if (modifiers.contains(HotkeyModifier.shift)) mask |= _modShift;
  if (modifiers.contains(HotkeyModifier.meta)) mask |= _modWin;
  return mask;
}
