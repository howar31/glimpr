import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../capture/captured_display.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_core.dart';
import '../editor/hud_config.dart';
import '../editor/loupe_config.dart';
import '../shortcuts/hotkey_binding.dart';
import 'overlay_editor_host.dart';

/// In-overlay annotation editor for ONE display. Thin wrapper: builds the shared
/// [EditorCore] with an [OverlayEditorHost] adapter (native cursor + cross-display
/// active signal + window-snap + export-region commit). All editor behavior lives
/// in EditorCore; this only adapts the overlay's host concerns.
class EditorCanvas extends StatelessWidget {
  final CapturedDisplay display;
  final ui.Image frozenImage;
  final EditorController controller;
  final Future<void> Function(Rect? selectionLogical, SnapWindow? window) onExport;
  final VoidCallback onCancel;
  final ValueListenable<({int id, Offset cursor})> activeSignal;
  final bool rightClickExits;
  final Map<String, HotkeyBinding?> editorBindings;
  final LoupeConfig loupe;
  final HudConfig hud;
  // The captured OS mouse pointer (toggleable cursor layer) + its logical
  // top-left; null when there is none.
  final ui.Image? cursorImage;
  final Offset? cursorTopLeft;

  const EditorCanvas({
    super.key,
    required this.display,
    required this.frozenImage,
    required this.controller,
    required this.onExport,
    required this.onCancel,
    required this.activeSignal,
    required this.editorBindings,
    this.loupe = const LoupeConfig(),
    this.hud = const HudConfig(),
    this.rightClickExits = true,
    this.cursorImage,
    this.cursorTopLeft,
  });

  @override
  Widget build(BuildContext context) {
    return EditorCore(
      controller: controller,
      editorBindings: editorBindings,
      loupe: loupe,
      hud: hud,
      host: OverlayEditorHost(
        display: display,
        frozen: frozenImage,
        activeSignal: activeSignal,
        rightClickExits: rightClickExits,
        onExport: onExport,
        onCancel: onCancel,
        cursorImage: cursorImage,
        cursorTopLeft: cursorTopLeft,
      ),
    );
  }
}
