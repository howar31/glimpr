import 'package:flutter/services.dart';
import '../editor/editor_controller.dart';
import 'hotkey_binding.dart';

// Action keys (naming: <scope>.<camelCaseName>).
const kCaptureAreaKey = 'global.captureArea';
const kCaptureScreenKey = 'global.captureScreen';
const kCaptureWindowKey = 'global.captureWindow';
const kCaptureLastRegionKey = 'global.captureLastRegion';
const kOpenEditorKey = 'global.openEditor';
const kOpenEditorClipboardKey = 'global.openEditorClipboard';

// Editor command keys.
const kEditorUndoKey = 'editor.undo';
const kEditorRedoKey = 'editor.redo';
const kEditorPasteKey = 'editor.pasteImage';
const kEditorDeleteKey = 'editor.deleteSelected';
const kEditorConfirmKey = 'editor.confirmExport';
const kEditorDuplicateKey = 'editor.duplicateSelected';
const kEditorBringToFrontKey = 'editor.bringToFront';
const kEditorSendToBackKey = 'editor.sendToBack';

/// Maps each editor tool to its action key.
const kEditorToolActionKey = <ToolKind, String>{
  ToolKind.crop: 'editor.crop',
  ToolKind.blur: 'editor.blur',
  ToolKind.pixelate: 'editor.pixelate',
  ToolKind.rectangle: 'editor.rectangle',
  ToolKind.ellipse: 'editor.ellipse',
  ToolKind.line: 'editor.line',
  ToolKind.arrow: 'editor.arrow',
  ToolKind.pen: 'editor.pen',
  ToolKind.text: 'editor.text',
  ToolKind.highlighter: 'editor.highlighter',
  ToolKind.step: 'editor.step',
  ToolKind.stamp: 'editor.stamp',
  ToolKind.paste: 'editor.paste',
};

HotkeyBinding _b(
  PhysicalKeyboardKey p,
  LogicalKeyboardKey l, [
  Set<HotkeyModifier> m = const {},
]) =>
    HotkeyBinding(physicalKey: p, logicalKey: l, modifiers: m);

/// Factory defaults. Tier-1 + Tier-2 in one map (foundation; Tier-2 dispatch is
/// wired in Phase 4.1b). Mirrors the current hardcoded keys in editor_canvas.
final Map<String, HotkeyBinding> kDefaultBindings = {
  kCaptureAreaKey: _b(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  kCaptureWindowKey: _b(PhysicalKeyboardKey.digit2, LogicalKeyboardKey.digit2,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  kCaptureScreenKey: _b(PhysicalKeyboardKey.digit3, LogicalKeyboardKey.digit3,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  kCaptureLastRegionKey: _b(PhysicalKeyboardKey.digit4, LogicalKeyboardKey.digit4,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  kOpenEditorKey: _b(PhysicalKeyboardKey.digit6, LogicalKeyboardKey.digit6,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  kOpenEditorClipboardKey: _b(
      PhysicalKeyboardKey.digit5, LogicalKeyboardKey.digit5,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  // Editor commands
  kEditorUndoKey: _b(PhysicalKeyboardKey.keyZ, LogicalKeyboardKey.keyZ,
      {HotkeyModifier.meta}),
  kEditorRedoKey: _b(PhysicalKeyboardKey.keyZ, LogicalKeyboardKey.keyZ,
      {HotkeyModifier.meta, HotkeyModifier.shift}),
  kEditorPasteKey: _b(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV,
      {HotkeyModifier.meta}),
  kEditorDeleteKey:
      _b(PhysicalKeyboardKey.backspace, LogicalKeyboardKey.backspace),
  kEditorConfirmKey: _b(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter),
  kEditorDuplicateKey: _b(PhysicalKeyboardKey.keyD, LogicalKeyboardKey.keyD,
      {HotkeyModifier.meta}),
  kEditorBringToFrontKey: _b(
      PhysicalKeyboardKey.bracketRight, LogicalKeyboardKey.bracketRight,
      {HotkeyModifier.meta}),
  kEditorSendToBackKey: _b(
      PhysicalKeyboardKey.bracketLeft, LogicalKeyboardKey.bracketLeft,
      {HotkeyModifier.meta}),
  // Editor tools
  kEditorToolActionKey[ToolKind.crop]!:
      _b(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC),
  kEditorToolActionKey[ToolKind.blur]!:
      _b(PhysicalKeyboardKey.keyB, LogicalKeyboardKey.keyB),
  kEditorToolActionKey[ToolKind.pixelate]!:
      _b(PhysicalKeyboardKey.keyP, LogicalKeyboardKey.keyP),
  kEditorToolActionKey[ToolKind.rectangle]!:
      _b(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1),
  kEditorToolActionKey[ToolKind.ellipse]!:
      _b(PhysicalKeyboardKey.digit2, LogicalKeyboardKey.digit2),
  kEditorToolActionKey[ToolKind.line]!:
      _b(PhysicalKeyboardKey.digit3, LogicalKeyboardKey.digit3),
  kEditorToolActionKey[ToolKind.arrow]!:
      _b(PhysicalKeyboardKey.digit4, LogicalKeyboardKey.digit4),
  kEditorToolActionKey[ToolKind.pen]!:
      _b(PhysicalKeyboardKey.digit5, LogicalKeyboardKey.digit5),
  kEditorToolActionKey[ToolKind.text]!:
      _b(PhysicalKeyboardKey.keyT, LogicalKeyboardKey.keyT),
  kEditorToolActionKey[ToolKind.highlighter]!:
      _b(PhysicalKeyboardKey.keyH, LogicalKeyboardKey.keyH),
  kEditorToolActionKey[ToolKind.step]!:
      _b(PhysicalKeyboardKey.keyS, LogicalKeyboardKey.keyS),
  // Image stamp tool — I (Image).
  kEditorToolActionKey[ToolKind.stamp]!:
      _b(PhysicalKeyboardKey.keyI, LogicalKeyboardKey.keyI),
  // The "paste" slot is the universal Select tool — V (the standard selection-
  // tool key in design apps); ⌘V remains the paste-image action.
  kEditorToolActionKey[ToolKind.paste]!:
      _b(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV),
};

/// Keys reserved for fixed editor behavior — cannot be bound to an editor action
/// (recorder rejects them). Esc = safety Cancel/Exit; arrows = crosshair nudge.
final kEditorReservedKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

/// A bindable global action. Only actions with a handler appear here, so the
/// Shortcuts UI renders no dead rows. This slice: captureArea only.
class GlobalAction {
  const GlobalAction({
    required this.actionKey,
    required this.label,
    required this.hint,
  });
  final String actionKey;
  final String label;
  final String hint;
}

const kGlobalActions = <GlobalAction>[
  GlobalAction(
    actionKey: kCaptureAreaKey,
    label: 'Capture',
    hint: 'Start a screen capture',
  ),
  GlobalAction(
    actionKey: kCaptureWindowKey,
    label: 'Capture Window',
    hint: 'Capture the focused window',
  ),
  GlobalAction(
    actionKey: kCaptureScreenKey,
    label: 'Capture Display',
    hint: 'Capture the display under the cursor',
  ),
  GlobalAction(
    actionKey: kCaptureLastRegionKey,
    label: 'Capture Last Region',
    hint: 'Repeat the last capture region',
  ),
  GlobalAction(
    actionKey: kOpenEditorKey,
    label: 'Open Editor',
    hint: 'Open the Image Editor',
  ),
  GlobalAction(
    actionKey: kOpenEditorClipboardKey,
    label: 'Open Editor with Clipboard',
    hint: 'Open the Image Editor and load the clipboard image',
  ),
];

/// The FIXED (reserved, not rebindable) Open-Settings chord: ⌘, (the macOS
/// Preferences convention). True only for a key-down of comma with EXACTLY the
/// meta modifier held.
bool isOpenSettingsChord(KeyEvent e, Set<HotkeyModifier> pressed) =>
    e is KeyDownEvent &&
    e.logicalKey == LogicalKeyboardKey.comma &&
    pressed.length == 1 &&
    pressed.contains(HotkeyModifier.meta);

/// Pure Tier-2 dispatch: given a key-down event, the currently-pressed modifier
/// set, and the effective editor bindings, return the matching editor action key
/// (a command key or a tool action key), or null. Commands are checked before
/// tools; order is otherwise irrelevant because matching is exact (modifier-set
/// equality) and duplicates are blocked at edit time.
String? pickEditorAction(
  KeyEvent e,
  Set<HotkeyModifier> pressed,
  Map<String, HotkeyBinding?> bindings,
) {
  const commands = [
    kEditorUndoKey,
    kEditorRedoKey,
    kEditorPasteKey,
    kEditorDeleteKey,
    kEditorConfirmKey,
    kEditorDuplicateKey,
    kEditorBringToFrontKey,
    kEditorSendToBackKey,
  ];
  for (final k in commands) {
    final b = bindings[k];
    if (b != null && b.matches(e, pressed)) return k;
  }
  for (final entry in kEditorToolActionKey.entries) {
    final b = bindings[entry.value];
    if (b != null && b.matches(e, pressed)) return entry.value;
  }
  return null;
}
