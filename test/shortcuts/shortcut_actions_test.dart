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

  test('captureArea default is Cmd+Opt+1', () {
    final b = kDefaultBindings[kCaptureAreaKey]!;
    expect(b.modifiers, {HotkeyModifier.meta, HotkeyModifier.alt});
  });

  test('global registry contains the 4 global capture actions', () {
    expect(kGlobalActions.map((a) => a.actionKey), [
      kCaptureAreaKey,
      kCaptureScreenKey,
      kCaptureWindowKey,
      kCaptureLastRegionKey,
    ]);
  });
}
