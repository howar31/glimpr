import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';

void main() {
  const cmdOpt1 = HotkeyBinding(
    physicalKey: PhysicalKeyboardKey.digit1,
    logicalKey: LogicalKeyboardKey.digit1,
    modifiers: {HotkeyModifier.meta, HotkeyModifier.alt},
  );

  test('Enter / numpad Enter render the monochrome ⏎ (not the ↩ emoji)', () {
    expect(keyLabelOf(LogicalKeyboardKey.enter), '⏎');
    expect(keyLabelOf(LogicalKeyboardKey.numpadEnter), '⏎');
  });

  test('toJson/fromJson round-trips', () {
    final json = cmdOpt1.toJson();
    final back = HotkeyBinding.fromJson(json);
    expect(back, cmdOpt1);
  });

  test('fromJson returns null on unknown ids', () {
    expect(HotkeyBinding.fromJson({'phys': 999999999, 'logi': 1, 'mods': []}),
        isNull);
    expect(HotkeyBinding.fromJson({'phys': 0x070000001e, 'logi': 999999999, 'mods': []}),
        isNull);
  });

  test('fromJson drops unknown modifier names', () {
    final b = HotkeyBinding.fromJson({
      'phys': PhysicalKeyboardKey.keyC.usbHidUsage,
      'logi': LogicalKeyboardKey.keyC.keyId,
      'mods': ['meta', 'win'], // 'win' unknown -> dropped
    });
    expect(b!.modifiers, {HotkeyModifier.meta});
  });

  test('isComplete (bare keys are valid bindings)', () {
    expect(cmdOpt1.isComplete, isTrue);
    // Modifier requirement was dropped (ShareX parity): a bare key is a
    // complete binding too.
    const bareC = HotkeyBinding(
      physicalKey: PhysicalKeyboardKey.keyC,
      logicalKey: LogicalKeyboardKey.keyC,
      modifiers: {},
    );
    expect(bareC.isComplete, isTrue);
  });

  test('equality by value', () {
    expect(
      const HotkeyBinding(
        physicalKey: PhysicalKeyboardKey.digit1,
        logicalKey: LogicalKeyboardKey.digit1,
        modifiers: {HotkeyModifier.alt, HotkeyModifier.meta},
      ),
      cmdOpt1,
    );
  });
}
