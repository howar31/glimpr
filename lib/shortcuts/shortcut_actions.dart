import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import '../editor/editor_controller.dart';
import '../l10n/gen/app_localizations.dart';
import 'hotkey_binding.dart';

/// Localized display name / hint for a Tier-1 global action (the Settings >
/// Shortcuts rows). The [GlobalAction.label]/[GlobalAction.hint] constants
/// stay as the English reference, but UI must read these lookups.
String globalActionLabel(AppLocalizations l10n, String actionKey) =>
    switch (actionKey) {
      kCaptureAreaKey => l10n.actionCapture,
      kCaptureWindowKey => l10n.actionCaptureWindow,
      kCaptureScreenKey => l10n.actionCaptureDisplay,
      kCaptureLastRegionKey => l10n.actionCaptureLastRegion,
      kOpenEditorKey => l10n.actionOpenEditor,
      kOpenEditorClipboardKey => l10n.actionOpenEditorClipboard,
      kPinAreaKey => l10n.actionPinCapture,
      kPinClipboardKey => l10n.actionPinClipboard,
      kRecordRegionKey => l10n.actionRecordRegion,
      kRecordWindowKey => l10n.actionRecordWindow,
      kRecordDisplayKey => l10n.actionRecordDisplay,
      kRecordLastRegionKey => l10n.actionRecordLastRegion,
      _ => actionKey,
    };

String globalActionHint(AppLocalizations l10n, String actionKey) =>
    switch (actionKey) {
      kCaptureAreaKey => l10n.actionCaptureHint,
      kCaptureWindowKey => l10n.actionCaptureWindowHint,
      kCaptureScreenKey => l10n.actionCaptureDisplayHint,
      kCaptureLastRegionKey => l10n.actionCaptureLastRegionHint,
      kOpenEditorKey => l10n.actionOpenEditorHint,
      kOpenEditorClipboardKey => l10n.actionOpenEditorClipboardHint,
      kPinAreaKey => l10n.actionPinCaptureHint,
      kPinClipboardKey => l10n.actionPinClipboardHint,
      kRecordRegionKey => l10n.actionRecordRegionHint,
      kRecordWindowKey => l10n.actionRecordWindowHint,
      kRecordDisplayKey => l10n.actionRecordDisplayHint,
      kRecordLastRegionKey => l10n.actionRecordLastRegionHint,
      _ => '',
    };

// Action keys (naming: <scope>.<camelCaseName>).
const kCaptureAreaKey = 'global.captureArea';
const kCaptureScreenKey = 'global.captureScreen';
const kCaptureWindowKey = 'global.captureWindow';
const kCaptureLastRegionKey = 'global.captureLastRegion';
const kOpenEditorKey = 'global.openEditor';
const kOpenEditorClipboardKey = 'global.openEditorClipboard';
const kPinAreaKey = 'global.pinArea';
const kPinClipboardKey = 'global.pinClipboard';
// Screen recording (macOS 15+; the dispatcher no-ops when unavailable). Every
// record action TOGGLES: starts its mode when idle, stops the active
// recording otherwise.
const kRecordRegionKey = 'global.recordRegion';
const kRecordWindowKey = 'global.recordWindow';
const kRecordDisplayKey = 'global.recordDisplay';
const kRecordLastRegionKey = 'global.recordLastRegion';

/// The recording actions, for UI grouping (own Shortcuts section / pane).
const kRecordActionKeys = <String>{
  kRecordRegionKey,
  kRecordWindowKey,
  kRecordDisplayKey,
  kRecordLastRegionKey,
};

// Editor command keys.
const kEditorUndoKey = 'editor.undo';
const kEditorRedoKey = 'editor.redo';
const kEditorPasteKey = 'editor.pasteImage';
const kEditorDeleteKey = 'editor.deleteSelected';
const kEditorConfirmKey = 'editor.confirmExport';
const kEditorDuplicateKey = 'editor.duplicateSelected';
const kEditorBringToFrontKey = 'editor.bringToFront';
const kEditorSendToBackKey = 'editor.sendToBack';
// Eyedropper color-copy keys: copy the loupe's aimed color to the clipboard
// in one format each. Act ONLY while the color picker is sampling.
const kEditorCopyHexKey = 'editor.copyColorHex';
const kEditorCopyRgbKey = 'editor.copyColorRgb';
const kEditorCopyHslKey = 'editor.copyColorHsl';
// HUD toggles: flip the per-session crosshair-lines / pixel-loupe override.
// Rebindable; defaults to bare X (crosshair) / Q (loupe). Unbind to disable.
const kEditorToggleCrosshairKey = 'editor.toggleCrosshair';
const kEditorToggleLoupeKey = 'editor.toggleLoupe';

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
  ToolKind.magnify: 'editor.magnify',
  ToolKind.spotlight: 'editor.spotlight',
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
  kOpenEditorKey: _b(PhysicalKeyboardKey.digit9, LogicalKeyboardKey.digit9,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  kOpenEditorClipboardKey: _b(
      PhysicalKeyboardKey.digit0, LogicalKeyboardKey.digit0,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  // Pin to screen: ⌘⌥5 = capture a region straight to a pin; ⌘⌥6 = pin the
  // clipboard image (no capture).
  kPinAreaKey: _b(PhysicalKeyboardKey.digit5, LogicalKeyboardKey.digit5,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  kPinClipboardKey: _b(PhysicalKeyboardKey.digit6, LogicalKeyboardKey.digit6,
      {HotkeyModifier.meta, HotkeyModifier.alt}),
  // Screen recording toggles: ⌃⌘1 region, ⌃⌘2 window, ⌃⌘3 display, ⌃⌘4 last
  // region. NOT ⌘⌥⇧ + digit: ⌘⇧3/4/5 are macOS system screenshot shortcuts and
  // the OS matches that ⌘⇧+digit core even with an extra ⌥ (it grabs the event
  // before the app), so the old ⌘⌥⇧3/4 were swallowed by the screenshot tool.
  // Control+Command avoids ⇧ entirely, so it never collides with screenshots.
  kRecordRegionKey: _b(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1,
      {HotkeyModifier.meta, HotkeyModifier.control}),
  kRecordWindowKey: _b(PhysicalKeyboardKey.digit2, LogicalKeyboardKey.digit2,
      {HotkeyModifier.meta, HotkeyModifier.control}),
  kRecordDisplayKey: _b(PhysicalKeyboardKey.digit3, LogicalKeyboardKey.digit3,
      {HotkeyModifier.meta, HotkeyModifier.control}),
  kRecordLastRegionKey: _b(
      PhysicalKeyboardKey.digit4, LogicalKeyboardKey.digit4,
      {HotkeyModifier.meta, HotkeyModifier.control}),
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
  // Shift-letter (NOT alt: macOS alt+letter yields a special-character
  // logical key that never matches; shift keeps the letter's logical key and
  // the modifier set distinguishes these from the plain-letter tool keys).
  kEditorCopyHexKey: _b(PhysicalKeyboardKey.keyH, LogicalKeyboardKey.keyH,
      {HotkeyModifier.shift}),
  kEditorCopyRgbKey: _b(PhysicalKeyboardKey.keyR, LogicalKeyboardKey.keyR,
      {HotkeyModifier.shift}),
  kEditorCopyHslKey: _b(PhysicalKeyboardKey.keyL, LogicalKeyboardKey.keyL,
      {HotkeyModifier.shift}),
  // HUD toggles — bare X (crosshair) / Q (loupe), in the bare-key "while aiming"
  // family (like the , / . element walk and the / loupe-info cycle). Rebindable.
  kEditorToggleCrosshairKey:
      _b(PhysicalKeyboardKey.keyX, LogicalKeyboardKey.keyX),
  kEditorToggleLoupeKey: _b(PhysicalKeyboardKey.keyQ, LogicalKeyboardKey.keyQ),
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
  // Magnify callout — M.
  kEditorToolActionKey[ToolKind.magnify]!:
      _b(PhysicalKeyboardKey.keyM, LogicalKeyboardKey.keyM),
  // Spotlight (dim-focus) — L (Light).
  kEditorToolActionKey[ToolKind.spotlight]!:
      _b(PhysicalKeyboardKey.keyL, LogicalKeyboardKey.keyL),
  // The "paste" slot is the universal Select tool — V (the standard selection-
  // tool key in design apps); ⌘V remains the paste-image action.
  kEditorToolActionKey[ToolKind.paste]!:
      _b(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV),
};

/// Windows-specific default overrides, merged over [kDefaultBindings] on Windows.
/// Rationale: meta maps to the Win key, and Win+Alt+digit collides with the
/// taskbar jump-list (and Win-key combos are broadly reserved), so the capture
/// globals get Ctrl+Alt+Win+digit; the not-yet-built globals are disabled (null);
/// and the LIVE overlay-editor command keys move meta -> control. No migration
/// code: changing a default is just changing a default.
final Map<String, HotkeyBinding?> kWindowsDefaultOverrides = {
  // Capture globals: Ctrl+Alt+Win+1..4.
  kCaptureAreaKey: _b(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1,
      {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta}),
  kCaptureWindowKey: _b(PhysicalKeyboardKey.digit2, LogicalKeyboardKey.digit2,
      {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta}),
  kCaptureScreenKey: _b(PhysicalKeyboardKey.digit3, LogicalKeyboardKey.digit3,
      {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta}),
  kCaptureLastRegionKey: _b(
      PhysicalKeyboardKey.digit4, LogicalKeyboardKey.digit4,
      {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta}),
  // Pin / open-editor globals (S4): Ctrl+Alt+Win+5/6/9/0, mirroring macOS
  // ⌘⌥5/6/9/0. NOTE: only 1-4 were field-tested for OS collision; 5/6/9/0 are
  // unverified (rebindable, so the user can clear any that collide).
  kPinAreaKey: _b(PhysicalKeyboardKey.digit5, LogicalKeyboardKey.digit5,
      {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta}),
  kPinClipboardKey: _b(PhysicalKeyboardKey.digit6, LogicalKeyboardKey.digit6,
      {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta}),
  kOpenEditorKey: _b(PhysicalKeyboardKey.digit9, LogicalKeyboardKey.digit9,
      {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta}),
  kOpenEditorClipboardKey: _b(
      PhysicalKeyboardKey.digit0, LogicalKeyboardKey.digit0,
      {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta}),
  // Recording (S6): Ctrl+Alt+Win+Shift+digit -- a collision-free combo parallel
  // to the capture globals (Ctrl+Alt+Win+digit), the way macOS recording
  // (Ctrl+Cmd+digit) differs from capture (Cmd+Alt+digit) by its modifier set.
  // region 1 / window 2 / display 3 / last-region 4, mirroring the macOS order.
  kRecordRegionKey: _b(PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1, {
    HotkeyModifier.control,
    HotkeyModifier.alt,
    HotkeyModifier.meta,
    HotkeyModifier.shift,
  }),
  kRecordWindowKey: _b(PhysicalKeyboardKey.digit2, LogicalKeyboardKey.digit2, {
    HotkeyModifier.control,
    HotkeyModifier.alt,
    HotkeyModifier.meta,
    HotkeyModifier.shift,
  }),
  kRecordDisplayKey: _b(PhysicalKeyboardKey.digit3, LogicalKeyboardKey.digit3, {
    HotkeyModifier.control,
    HotkeyModifier.alt,
    HotkeyModifier.meta,
    HotkeyModifier.shift,
  }),
  kRecordLastRegionKey: _b(
      PhysicalKeyboardKey.digit4, LogicalKeyboardKey.digit4, {
    HotkeyModifier.control,
    HotkeyModifier.alt,
    HotkeyModifier.meta,
    HotkeyModifier.shift,
  }),
  // Editor command keys: the overlay editor is LIVE on Windows (S2b), so its
  // meta-modified commands must be Ctrl-based now (undo/redo/paste/duplicate/
  // z-order). Modifier-light tool/command keys (C/B/P, digits, Shift+letters,
  // Delete, Enter) are already cross-platform and stay shared.
  kEditorUndoKey: _b(PhysicalKeyboardKey.keyZ, LogicalKeyboardKey.keyZ,
      {HotkeyModifier.control}),
  kEditorRedoKey: _b(PhysicalKeyboardKey.keyZ, LogicalKeyboardKey.keyZ,
      {HotkeyModifier.control, HotkeyModifier.shift}),
  kEditorPasteKey: _b(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV,
      {HotkeyModifier.control}),
  kEditorDuplicateKey: _b(PhysicalKeyboardKey.keyD, LogicalKeyboardKey.keyD,
      {HotkeyModifier.control}),
  kEditorBringToFrontKey: _b(
      PhysicalKeyboardKey.bracketRight, LogicalKeyboardKey.bracketRight,
      {HotkeyModifier.control}),
  kEditorSendToBackKey: _b(
      PhysicalKeyboardKey.bracketLeft, LogicalKeyboardKey.bracketLeft,
      {HotkeyModifier.control}),
};

/// Global actions not available on Windows (greyed in the tray, hidden in the
/// Shortcuts pane, disabled as hotkeys). Empty since Phase 6 completed -- every
/// global action is wired on Windows; the seam stays for any future
/// platform-gated action.
const _kWindowsUnavailableGlobals = <String>{};

/// Whether a Tier-1 global action is available on the current platform. macOS:
/// always. Windows: everything except the not-yet-built globals.
bool isGlobalActionAvailable(String actionKey, {bool? isWindows}) =>
    !(isWindows ?? Platform.isWindows) ||
    !_kWindowsUnavailableGlobals.contains(actionKey);

/// The effective default bindings for [isWindows]: the macOS map, with the
/// Windows overrides merged on top when [isWindows]. Pure (testable) function.
Map<String, HotkeyBinding?> defaultBindingsFor(bool isWindows) => isWindows
    ? {...kDefaultBindings, ...kWindowsDefaultOverrides}
    : {...kDefaultBindings};

/// The effective default bindings on THIS platform.
Map<String, HotkeyBinding?> effectiveDefaultBindings() =>
    defaultBindingsFor(Platform.isWindows);

/// The platform-effective default binding for [actionKey] (null = disabled).
HotkeyBinding? defaultBindingFor(String actionKey) =>
    effectiveDefaultBindings()[actionKey];

/// The "command" modifier for the editor's FIXED chords (close / open-settings /
/// fit / zoom): meta on macOS, control on Windows (where meta is the Win key and
/// Win+W/Win+, are OS shortcuts). Pure (testable) — pass [isWindows] to override
/// the host platform.
HotkeyModifier editorCommandModifier({bool? isWindows}) =>
    (isWindows ?? Platform.isWindows)
        ? HotkeyModifier.control
        : HotkeyModifier.meta;

/// Whether the platform command modifier ([editorCommandModifier]) is held
/// right now: meta on macOS, control on Windows (meta there is the Win key).
bool isCommandModifierPressed() => Platform.isWindows
    ? HardwareKeyboard.instance.isControlPressed
    : HardwareKeyboard.instance.isMetaPressed;

/// Keys reserved as WHOLE keys (rejected with any modifier combination). Esc =
/// safety Cancel/Exit; arrows = crosshair nudge.
final kEditorReservedKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

/// Reserved as EXACT combos (this key with exactly these modifiers). Bare , / .
/// walk the element-snap level; bare / and Shift+/ (= ?) cycle the loupe info;
/// the chords are the fixed editor/system shortcuts ⌘W (close window), ⌘,
/// (open settings), ⌘1 (fit to window), ⌘2 (zoom to 100%). Enter and Shift+Enter
/// are intentionally absent: Enter is the rebindable Export command default and
/// is suppressed only while editing a text annotation.
///
/// NOTE: Shift+/ reports the logical key `question` (NOT slash+Shift), so the
/// loupe-cycle key is reserved under BOTH `slash` and `question` to match what
/// the recorder actually captures.
List<(LogicalKeyboardKey, Set<HotkeyModifier>)> _editorReservedCombos(
    bool isWindows) {
  final cmd = editorCommandModifier(isWindows: isWindows);
  return [
    (LogicalKeyboardKey.comma, const {}),
    (LogicalKeyboardKey.period, const {}),
    (LogicalKeyboardKey.slash, const {}),
    (LogicalKeyboardKey.slash, const {HotkeyModifier.shift}),
    (LogicalKeyboardKey.question, const {}),
    (LogicalKeyboardKey.question, const {HotkeyModifier.shift}),
    (LogicalKeyboardKey.keyW, {cmd}),
    (LogicalKeyboardKey.comma, {cmd}),
    (LogicalKeyboardKey.digit1, {cmd}),
    (LogicalKeyboardKey.digit2, {cmd}),
  ];
}

/// Whether binding [key] with [modifiers] would collide with a fixed editor or
/// system shortcut, so the recorder rejects it on every binding row. Whole-key
/// reserved (esc / arrows) match regardless of modifiers; the rest match the
/// exact combo, so the bare 1/2 tools and ⌘. / ⌘/ stay bindable.
bool isEditorReservedCombo(
  LogicalKeyboardKey key,
  Set<HotkeyModifier> modifiers, {
  bool? isWindows,
}) {
  if (kEditorReservedKeys.contains(key)) return true;
  for (final (k, mods) in _editorReservedCombos(isWindows ?? Platform.isWindows)) {
    if (k == key &&
        mods.length == modifiers.length &&
        mods.containsAll(modifiers)) {
      return true;
    }
  }
  return false;
}

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
    label: 'Screenshot Region',
    hint: 'Select a region and screenshot it',
  ),
  GlobalAction(
    actionKey: kCaptureWindowKey,
    label: 'Screenshot Window',
    hint: 'Screenshot the focused window',
  ),
  GlobalAction(
    actionKey: kCaptureScreenKey,
    label: 'Screenshot Display',
    hint: 'Screenshot the display under the cursor',
  ),
  GlobalAction(
    actionKey: kCaptureLastRegionKey,
    label: 'Screenshot Last Region',
    hint: 'Repeat the last screenshot region',
  ),
  GlobalAction(
    actionKey: kOpenEditorKey,
    label: 'Open Image Editor',
    hint: 'Open the Image Editor',
  ),
  GlobalAction(
    actionKey: kOpenEditorClipboardKey,
    label: 'Open Image Editor with Clipboard',
    hint: 'Open the Image Editor and load the clipboard image',
  ),
  GlobalAction(
    actionKey: kPinAreaKey,
    label: 'Pin Screenshot',
    hint: 'Screenshot a region straight to a floating pin',
  ),
  GlobalAction(
    actionKey: kPinClipboardKey,
    label: 'Pin Clipboard',
    hint: 'Float the clipboard image as a pin',
  ),
  GlobalAction(
    actionKey: kRecordRegionKey,
    label: 'Record Region',
    hint: 'Record a screen region; press again to stop',
  ),
  GlobalAction(
    actionKey: kRecordWindowKey,
    label: 'Record Window',
    hint: 'Record the focused window; press again to stop',
  ),
  GlobalAction(
    actionKey: kRecordDisplayKey,
    label: 'Record Display',
    hint: 'Record the display under the cursor; press again to stop',
  ),
  GlobalAction(
    actionKey: kRecordLastRegionKey,
    label: 'Record Last Region',
    hint: 'Repeat the last recording region; press again to stop',
  ),
];

/// The FIXED (reserved, not rebindable) Open-Settings chord: ⌘, on macOS, Ctrl+,
/// on Windows (the platform Preferences/Settings convention). True only for a
/// key-down of comma with EXACTLY the command modifier held.
bool isOpenSettingsChord(KeyEvent e, Set<HotkeyModifier> pressed,
        {bool? isWindows}) =>
    e is KeyDownEvent &&
    e.logicalKey == LogicalKeyboardKey.comma &&
    pressed.length == 1 &&
    pressed.contains(editorCommandModifier(isWindows: isWindows));

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
    kEditorCopyHexKey,
    kEditorCopyRgbKey,
    kEditorCopyHslKey,
    kEditorToggleCrosshairKey,
    kEditorToggleLoupeKey,
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
