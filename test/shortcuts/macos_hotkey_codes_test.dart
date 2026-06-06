import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/macos_hotkey_codes.dart';

void main() {
  // kVK_ANSI_* virtual keycodes from <Carbon/HIToolbox/Events.h>.
  test('the default global-hotkey digits map to their kVK codes', () {
    expect(macOSKeyCode(PhysicalKeyboardKey.digit1), 0x12); // kVK_ANSI_1
    expect(macOSKeyCode(PhysicalKeyboardKey.digit2), 0x13);
    expect(macOSKeyCode(PhysicalKeyboardKey.digit3), 0x14);
    expect(macOSKeyCode(PhysicalKeyboardKey.digit4), 0x15);
    expect(macOSKeyCode(PhysicalKeyboardKey.digit5), 0x17); // 23
    expect(macOSKeyCode(PhysicalKeyboardKey.digit6), 0x16); // 22
  });

  test('representative letters / arrows / punctuation map correctly', () {
    expect(macOSKeyCode(PhysicalKeyboardKey.keyA), 0x00); // kVK_ANSI_A
    expect(macOSKeyCode(PhysicalKeyboardKey.keyC), 0x08);
    expect(macOSKeyCode(PhysicalKeyboardKey.comma), 0x2B);
    expect(macOSKeyCode(PhysicalKeyboardKey.space), 0x31);
    expect(macOSKeyCode(PhysicalKeyboardKey.arrowLeft), 0x7B);
    expect(macOSKeyCode(PhysicalKeyboardKey.f1), 0x7A);
  });

  test('an unmappable key returns null (caller falls back / skips)', () {
    expect(macOSKeyCode(PhysicalKeyboardKey.fn), isNull);
  });

  test('carbon modifier mask matches the Carbon constants', () {
    expect(carbonModifierMask(const {HotkeyModifier.meta}), 0x100); // cmdKey
    expect(carbonModifierMask(const {HotkeyModifier.shift}), 0x200); // shiftKey
    expect(carbonModifierMask(const {HotkeyModifier.alt}), 0x800); // optionKey
    expect(carbonModifierMask(const {HotkeyModifier.control}), 0x1000); // controlKey
    expect(carbonModifierMask(const {}), 0);
    expect(
      carbonModifierMask(const {HotkeyModifier.meta, HotkeyModifier.alt}),
      0x100 | 0x800,
    );
  });
}
