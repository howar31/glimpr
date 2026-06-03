import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';

void main() {
  final keyC = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyC,
    logicalKey: LogicalKeyboardKey.keyC,
    timeStamp: Duration.zero,
  );
  final keyB = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyB,
    logicalKey: LogicalKeyboardKey.keyB,
    timeStamp: Duration.zero,
  );
  final keyZ = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyZ,
    logicalKey: LogicalKeyboardKey.keyZ,
    timeStamp: Duration.zero,
  );
  final keyEnter = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.enter,
    logicalKey: LogicalKeyboardKey.enter,
    timeStamp: Duration.zero,
  );
  final keyV = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyV,
    logicalKey: LogicalKeyboardKey.keyV,
    timeStamp: Duration.zero,
  );
  final keyBackspace = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.backspace,
    logicalKey: LogicalKeyboardKey.backspace,
    timeStamp: Duration.zero,
  );

  test('bare C selects crop under default bindings', () {
    expect(
      pickEditorAction(keyC, {}, kDefaultBindings),
      kEditorToolActionKey[ToolKind.crop],
    );
  });

  test('Cmd-C does not match bare-C crop binding', () {
    expect(
      pickEditorAction(keyC, {HotkeyModifier.meta}, kDefaultBindings),
      isNull,
    );
  });

  test('custom Cmd-B binding matches exactly', () {
    final custom = {
      kEditorToolActionKey[ToolKind.blur]!: const HotkeyBinding(
        physicalKey: PhysicalKeyboardKey.keyB,
        logicalKey: LogicalKeyboardKey.keyB,
        modifiers: {HotkeyModifier.meta},
      ),
    };
    expect(
      pickEditorAction(keyB, {HotkeyModifier.meta}, custom),
      kEditorToolActionKey[ToolKind.blur],
    );
    expect(pickEditorAction(keyB, {}, custom), isNull);
  });

  test('empty bindings map dispatches nothing', () {
    expect(
      pickEditorAction(keyC, {}, const <String, HotkeyBinding?>{}),
      isNull,
    );
  });

  test('null binding entry (unbound tool) dispatches nothing', () {
    expect(
      pickEditorAction(keyC, {}, {kEditorToolActionKey[ToolKind.crop]!: null}),
      isNull,
    );
  });

  test('Cmd-Z = undo, Cmd-Shift-Z = redo under default bindings', () {
    expect(
      pickEditorAction(keyZ, {HotkeyModifier.meta}, kDefaultBindings),
      kEditorUndoKey,
    );
    expect(
      pickEditorAction(
        keyZ,
        {HotkeyModifier.meta, HotkeyModifier.shift},
        kDefaultBindings,
      ),
      kEditorRedoKey,
    );
  });

  test('command keys match their default editor actions', () {
    expect(pickEditorAction(keyEnter, {}, kDefaultBindings), kEditorConfirmKey);
    expect(
      pickEditorAction(keyV, {HotkeyModifier.meta}, kDefaultBindings),
      kEditorPasteKey,
    );
    expect(
      pickEditorAction(keyBackspace, {}, kDefaultBindings),
      kEditorDeleteKey,
    );
  });

  test('commands take precedence over a tool sharing the same combo', () {
    // Bind the crop tool onto bare Enter (the confirm default). pickEditorAction
    // checks commands before tools, so confirm wins.
    final bindings = {
      ...kDefaultBindings,
      kEditorToolActionKey[ToolKind.crop]!: const HotkeyBinding(
        physicalKey: PhysicalKeyboardKey.enter,
        logicalKey: LogicalKeyboardKey.enter,
        modifiers: {},
      ),
    };
    expect(pickEditorAction(keyEnter, {}, bindings), kEditorConfirmKey);
  });
}
