import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';

void main() {
  test('the three direct-capture actions are registered global actions', () {
    final keys = kGlobalActions.map((a) => a.actionKey).toSet();
    expect(keys, containsAll([
      kCaptureScreenKey,
      kCaptureWindowKey,
      kCaptureLastRegionKey,
    ]));
  });

  test('each direct-capture action has a default ⌘⌥digit binding', () {
    expect(kDefaultBindings[kCaptureScreenKey]!.logicalKey,
        LogicalKeyboardKey.digit2);
    expect(kDefaultBindings[kCaptureWindowKey]!.logicalKey,
        LogicalKeyboardKey.digit3);
    expect(kDefaultBindings[kCaptureLastRegionKey]!.logicalKey,
        LogicalKeyboardKey.digit4);
    for (final k in [kCaptureScreenKey, kCaptureWindowKey, kCaptureLastRegionKey]) {
      expect(kDefaultBindings[k]!.modifiers,
          {HotkeyModifier.meta, HotkeyModifier.alt}, reason: k);
    }
  });
}
