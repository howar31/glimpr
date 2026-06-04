import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';

void main() {
  test('every editor ToolKind has a default binding', () {
    for (final t in ToolKind.values) {
      expect(kEditorToolActionKey.containsKey(t), isTrue, reason: '$t');
      expect(kDefaultBindings[kEditorToolActionKey[t]], isNotNull, reason: '$t');
    }
  });

  test('text / highlighter / step / select default to T / H / S / V', () {
    LogicalKeyboardKey keyFor(ToolKind t) =>
        kDefaultBindings[kEditorToolActionKey[t]!]!.logicalKey;
    expect(keyFor(ToolKind.text), LogicalKeyboardKey.keyT);
    expect(keyFor(ToolKind.highlighter), LogicalKeyboardKey.keyH);
    expect(keyFor(ToolKind.step), LogicalKeyboardKey.keyS);
    // The "paste" slot is the universal Select tool — V (the industry-standard
    // selection-tool key).
    expect(keyFor(ToolKind.paste), LogicalKeyboardKey.keyV);
  });

  test('captureArea default is Cmd+Opt+1', () {
    final b = kDefaultBindings[kCaptureAreaKey]!;
    expect(b.modifiers, {HotkeyModifier.meta, HotkeyModifier.alt});
  });

  test('global registry contains the 4 global capture actions', () {
    expect(kGlobalActions.map((a) => a.actionKey), [
      kCaptureAreaKey,
      kCaptureWindowKey,
      kCaptureScreenKey,
      kCaptureLastRegionKey,
    ]);
  });
}
