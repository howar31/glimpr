import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';

void main() {
  test('non-Windows defaults are exactly kDefaultBindings', () {
    expect(defaultBindingsFor(false), kDefaultBindings);
  });

  test('Windows capture globals are Ctrl+Alt+Win+digit', () {
    final w = defaultBindingsFor(true);
    const ctrlAltWin = {
      HotkeyModifier.control,
      HotkeyModifier.alt,
      HotkeyModifier.meta,
    };
    expect(w[kCaptureAreaKey]!.physicalKey, PhysicalKeyboardKey.digit1);
    expect(w[kCaptureAreaKey]!.modifiers, ctrlAltWin);
    expect(w[kCaptureWindowKey]!.physicalKey, PhysicalKeyboardKey.digit2);
    expect(w[kCaptureWindowKey]!.modifiers, ctrlAltWin);
    expect(w[kCaptureScreenKey]!.physicalKey, PhysicalKeyboardKey.digit3);
    expect(w[kCaptureLastRegionKey]!.physicalKey, PhysicalKeyboardKey.digit4);
    // Display string the menu/UI shows.
    expect(w[kCaptureAreaKey]!.label(TargetPlatform.windows), 'Ctrl+Alt+Win+1');
  });

  test('deferred globals (pin / open-editor / record) are disabled on Windows', () {
    final w = defaultBindingsFor(true);
    expect(w[kPinAreaKey], isNull);
    expect(w[kPinClipboardKey], isNull);
    expect(w[kOpenEditorKey], isNull);
    expect(w[kOpenEditorClipboardKey], isNull);
    expect(w[kRecordRegionKey], isNull);
    expect(w[kRecordWindowKey], isNull);
    expect(w[kRecordDisplayKey], isNull);
    expect(w[kRecordLastRegionKey], isNull);
  });

  test('editor command keys are Ctrl-based on Windows (overlay editor is live)', () {
    final w = defaultBindingsFor(true);
    expect(w[kEditorUndoKey]!.modifiers, {HotkeyModifier.control});
    expect(w[kEditorUndoKey]!.physicalKey, PhysicalKeyboardKey.keyZ);
    expect(w[kEditorRedoKey]!.modifiers,
        {HotkeyModifier.control, HotkeyModifier.shift});
    expect(w[kEditorPasteKey]!.modifiers, {HotkeyModifier.control});
    expect(w[kEditorDuplicateKey]!.modifiers, {HotkeyModifier.control});
    expect(w[kEditorBringToFrontKey]!.modifiers, {HotkeyModifier.control});
    expect(w[kEditorSendToBackKey]!.modifiers, {HotkeyModifier.control});
  });

  test('modifier-light editor/tool keys stay shared on Windows', () {
    final w = defaultBindingsFor(true);
    // Tool keys with no modifier are identical to the macOS map.
    expect(w['editor.crop'], kDefaultBindings['editor.crop']);
    expect(w[kEditorDeleteKey], kDefaultBindings[kEditorDeleteKey]);
    expect(w[kEditorCopyHexKey], kDefaultBindings[kEditorCopyHexKey]);
  });

  test('availability: capture globals available, deferred unavailable on Windows', () {
    expect(isGlobalActionAvailable(kCaptureAreaKey, isWindows: true), isTrue);
    expect(isGlobalActionAvailable(kPinAreaKey, isWindows: true), isFalse);
    expect(isGlobalActionAvailable(kRecordRegionKey, isWindows: true), isFalse);
    // Everything is available on macOS.
    expect(isGlobalActionAvailable(kPinAreaKey, isWindows: false), isTrue);
    expect(isGlobalActionAvailable(kRecordRegionKey, isWindows: false), isTrue);
  });
}
