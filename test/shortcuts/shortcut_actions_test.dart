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

  group('isEditorReservedCombo', () {
    const none = <HotkeyModifier>{};
    const meta = {HotkeyModifier.meta};
    const shift = {HotkeyModifier.shift};

    test('reserves the bare element-snap / loupe keys', () {
      expect(isEditorReservedCombo(LogicalKeyboardKey.comma, none), isTrue);
      expect(isEditorReservedCombo(LogicalKeyboardKey.period, none), isTrue);
      expect(isEditorReservedCombo(LogicalKeyboardKey.slash, none), isTrue);
      // Shift+/ = ? cycles the loupe info. Flutter reports `?` as the logical
      // key `question` (not slash+Shift), so both must be reserved.
      expect(isEditorReservedCombo(LogicalKeyboardKey.slash, shift), isTrue);
      expect(isEditorReservedCombo(LogicalKeyboardKey.question, shift), isTrue);
      expect(isEditorReservedCombo(LogicalKeyboardKey.question, none), isTrue);
    });

    test('reserves the editor/system chords ⌘W / ⌘, / ⌘1 / ⌘2', () {
      expect(isEditorReservedCombo(LogicalKeyboardKey.keyW, meta), isTrue);
      expect(isEditorReservedCombo(LogicalKeyboardKey.comma, meta), isTrue);
      expect(isEditorReservedCombo(LogicalKeyboardKey.digit1, meta), isTrue);
      expect(isEditorReservedCombo(LogicalKeyboardKey.digit2, meta), isTrue);
    });

    test('keeps esc / arrows whole-key reserved', () {
      expect(isEditorReservedCombo(LogicalKeyboardKey.escape, none), isTrue);
      expect(isEditorReservedCombo(LogicalKeyboardKey.arrowUp, none), isTrue);
      expect(isEditorReservedCombo(LogicalKeyboardKey.arrowDown, none), isTrue);
    });

    test('does NOT reserve the bare digit tools or unrelated chords', () {
      // Rectangle / ellipse tools are bare 1 / 2 — must stay bindable.
      expect(isEditorReservedCombo(LogicalKeyboardKey.digit1, none), isFalse);
      expect(isEditorReservedCombo(LogicalKeyboardKey.digit2, none), isFalse);
      expect(isEditorReservedCombo(LogicalKeyboardKey.keyW, none), isFalse);
      // Only the precise chord is reserved, not the whole key.
      expect(isEditorReservedCombo(LogicalKeyboardKey.period, meta), isFalse);
      expect(isEditorReservedCombo(LogicalKeyboardKey.slash, meta), isFalse);
    });

    test('does NOT reserve Enter / Shift+Enter (Export default + text overload)',
        () {
      expect(isEditorReservedCombo(LogicalKeyboardKey.enter, none), isFalse);
      expect(isEditorReservedCombo(LogicalKeyboardKey.enter, shift), isFalse);
    });
  });
}
