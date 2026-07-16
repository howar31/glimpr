import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';

void main() {
  test('non-Windows defaults are exactly kDefaultBindings', () {
    expect(defaultBindingsFor(false), kDefaultBindings);
  });

  test('Windows capture globals are the PrintScreen family', () {
    final w = defaultBindingsFor(true);
    expect(w[kCaptureAreaKey]!.physicalKey, PhysicalKeyboardKey.printScreen);
    expect(w[kCaptureAreaKey]!.modifiers,
        {HotkeyModifier.shift, HotkeyModifier.meta});
    expect(w[kCaptureWindowKey]!.physicalKey, PhysicalKeyboardKey.printScreen);
    expect(w[kCaptureWindowKey]!.modifiers,
        {HotkeyModifier.control, HotkeyModifier.meta});
    // Bare PrintScreen = full screen; bare F14 = last region.
    expect(w[kCaptureScreenKey]!.physicalKey, PhysicalKeyboardKey.printScreen);
    expect(w[kCaptureScreenKey]!.modifiers, isEmpty);
    expect(w[kCaptureLastRegionKey]!.physicalKey, PhysicalKeyboardKey.f14);
    expect(w[kCaptureLastRegionKey]!.modifiers, isEmpty);
  });

  test('Windows binds pin/open-editor globals to Ctrl+Alt+Win+5/6/9/0; record modes bound', () {
    final w = defaultBindingsFor(true);
    const ctrlAltWin = {
      HotkeyModifier.control,
      HotkeyModifier.alt,
      HotkeyModifier.meta,
    };
    // Pin / open-editor land in S4 (mirror macOS ⌘⌥5/6/9/0).
    expect(w[kPinAreaKey]!.physicalKey, PhysicalKeyboardKey.digit5);
    expect(w[kPinAreaKey]!.modifiers, ctrlAltWin);
    expect(w[kPinClipboardKey]!.physicalKey, PhysicalKeyboardKey.digit6);
    expect(w[kPinClipboardKey]!.modifiers, ctrlAltWin);
    expect(w[kOpenEditorKey]!.physicalKey, PhysicalKeyboardKey.digit9);
    expect(w[kOpenEditorKey]!.modifiers, ctrlAltWin);
    expect(w[kOpenEditorClipboardKey]!.physicalKey, PhysicalKeyboardKey.digit0);
    expect(w[kOpenEditorClipboardKey]!.modifiers, ctrlAltWin);
    // GIF editor = the image-editor pair + Shift (owner default).
    const ctrlAltWinShiftGif = {
      HotkeyModifier.control,
      HotkeyModifier.alt,
      HotkeyModifier.meta,
      HotkeyModifier.shift,
    };
    expect(w[kOpenGifEditorKey]!.physicalKey, PhysicalKeyboardKey.digit9);
    expect(w[kOpenGifEditorKey]!.modifiers, ctrlAltWinShiftGif);
    expect(w[kOpenGifEditorClipboardKey]!.physicalKey,
        PhysicalKeyboardKey.digit0);
    expect(
        w[kOpenGifEditorClipboardKey]!.modifiers, ctrlAltWinShiftGif);
    // Record modes: region/last-region ride the capture-family keys with an
    // extra Ctrl (PrtScr / F14); window/display keep Ctrl+Alt+Win+Shift+2/3.
    const ctrlAltWinShift = {
      HotkeyModifier.control,
      HotkeyModifier.alt,
      HotkeyModifier.meta,
      HotkeyModifier.shift,
    };
    expect(w[kRecordRegionKey]!.physicalKey, PhysicalKeyboardKey.printScreen);
    expect(w[kRecordRegionKey]!.modifiers,
        {HotkeyModifier.control, HotkeyModifier.shift, HotkeyModifier.meta});
    expect(w[kRecordWindowKey]!.physicalKey, PhysicalKeyboardKey.digit2);
    expect(w[kRecordWindowKey]!.modifiers, ctrlAltWinShift);
    expect(w[kRecordDisplayKey]!.physicalKey, PhysicalKeyboardKey.digit3);
    expect(w[kRecordDisplayKey]!.modifiers, ctrlAltWinShift);
    expect(w[kRecordLastRegionKey]!.physicalKey, PhysicalKeyboardKey.f14);
    expect(w[kRecordLastRegionKey]!.modifiers, {HotkeyModifier.control});
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

  test('availability: capture + pin + open-editor + all record modes available on Windows', () {
    expect(isGlobalActionAvailable(kCaptureAreaKey, isWindows: true), isTrue);
    expect(isGlobalActionAvailable(kPinAreaKey, isWindows: true), isTrue);
    expect(isGlobalActionAvailable(kPinClipboardKey, isWindows: true), isTrue);
    expect(isGlobalActionAvailable(kOpenEditorKey, isWindows: true), isTrue);
    expect(
        isGlobalActionAvailable(kOpenEditorClipboardKey, isWindows: true), isTrue);
    // All recording modes are wired on Windows (S6).
    expect(isGlobalActionAvailable(kRecordDisplayKey, isWindows: true), isTrue);
    expect(isGlobalActionAvailable(kRecordRegionKey, isWindows: true), isTrue);
    expect(isGlobalActionAvailable(kRecordWindowKey, isWindows: true), isTrue);
    expect(
        isGlobalActionAvailable(kRecordLastRegionKey, isWindows: true), isTrue);
    // Everything is available on macOS.
    expect(isGlobalActionAvailable(kPinAreaKey, isWindows: false), isTrue);
    expect(isGlobalActionAvailable(kRecordRegionKey, isWindows: false), isTrue);
  });
}

