import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/windows_hotkey_codes.dart';

void main() {
  // Win32 virtual-key codes: digits '0'-'9' = 0x30-0x39, 'A'-'Z' = 0x41-0x5A.
  test('the default global-hotkey digits map to their VK codes', () {
    expect(win32VirtualKey(PhysicalKeyboardKey.digit1), 0x31);
    expect(win32VirtualKey(PhysicalKeyboardKey.digit2), 0x32);
    expect(win32VirtualKey(PhysicalKeyboardKey.digit3), 0x33);
    expect(win32VirtualKey(PhysicalKeyboardKey.digit4), 0x34);
    expect(win32VirtualKey(PhysicalKeyboardKey.digit0), 0x30);
  });

  test('representative letters / arrows / punctuation map correctly', () {
    expect(win32VirtualKey(PhysicalKeyboardKey.keyA), 0x41);
    expect(win32VirtualKey(PhysicalKeyboardKey.keyZ), 0x5A);
    expect(win32VirtualKey(PhysicalKeyboardKey.comma), 0xBC); // VK_OEM_COMMA
    expect(win32VirtualKey(PhysicalKeyboardKey.space), 0x20); // VK_SPACE
    expect(win32VirtualKey(PhysicalKeyboardKey.arrowLeft), 0x25); // VK_LEFT
    expect(win32VirtualKey(PhysicalKeyboardKey.f1), 0x70); // VK_F1
    expect(win32VirtualKey(PhysicalKeyboardKey.bracketRight), 0xDD); // VK_OEM_6
    expect(win32VirtualKey(PhysicalKeyboardKey.bracketLeft), 0xDB); // VK_OEM_4
  });

  test('an unmappable key returns null', () {
    expect(win32VirtualKey(PhysicalKeyboardKey.fn), isNull);
  });

  test('Win32 modifier mask matches the MOD_ constants', () {
    expect(win32ModifierMask(const {HotkeyModifier.alt}), 0x0001); // MOD_ALT
    expect(win32ModifierMask(const {HotkeyModifier.control}), 0x0002); // MOD_CONTROL
    expect(win32ModifierMask(const {HotkeyModifier.shift}), 0x0004); // MOD_SHIFT
    expect(win32ModifierMask(const {HotkeyModifier.meta}), 0x0008); // MOD_WIN
    expect(win32ModifierMask(const {}), 0);
    expect(
      win32ModifierMask(
          const {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta}),
      0x0002 | 0x0001 | 0x0008,
    );
  });
}
