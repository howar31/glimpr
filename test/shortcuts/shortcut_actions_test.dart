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

  test('global registry contains the capture + open-editor actions', () {
    expect(kGlobalActions.map((a) => a.actionKey), [
      kCaptureAreaKey,
      kCaptureWindowKey,
      kCaptureScreenKey,
      kCaptureLastRegionKey,
      kOpenEditorKey,
      kOpenEditorClipboardKey,
      kPinAreaKey,
      kPinClipboardKey,
      kRecordRegionKey,
      kRecordWindowKey,
      kRecordDisplayKey,
      kRecordLastRegionKey,
    ]);
  });

  test('isOpenSettingsChord matches Cmd+comma only', () {
    final comma = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.comma,
      logicalKey: LogicalKeyboardKey.comma,
      timeStamp: Duration.zero,
    );
    expect(isOpenSettingsChord(comma, {HotkeyModifier.meta}), isTrue);
    expect(isOpenSettingsChord(comma, const {}), isFalse); // bare comma
    expect(
      isOpenSettingsChord(comma, {HotkeyModifier.meta, HotkeyModifier.shift}),
      isFalse, // an extra modifier is not the chord
    );
    final keyA = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      timeStamp: Duration.zero,
    );
    expect(isOpenSettingsChord(keyA, {HotkeyModifier.meta}), isFalse);
  });

  test('open-editor defaults: empty = Cmd+Opt+9, clipboard = Cmd+Opt+0', () {
    final empty = kDefaultBindings[kOpenEditorKey]!;
    expect(empty.logicalKey, LogicalKeyboardKey.digit9);
    expect(empty.modifiers, {HotkeyModifier.meta, HotkeyModifier.alt});
    final clip = kDefaultBindings[kOpenEditorClipboardKey]!;
    expect(clip.logicalKey, LogicalKeyboardKey.digit0);
    expect(clip.modifiers, {HotkeyModifier.meta, HotkeyModifier.alt});
  });
}
