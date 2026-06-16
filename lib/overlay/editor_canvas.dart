import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../capture/captured_display.dart';
import '../capture/element_snap.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_core.dart';
import '../editor/hud_config.dart';
import '../editor/loupe_config.dart';
import '../shortcuts/hotkey_binding.dart';
import 'overlay_editor_host.dart';
import 'toolbar.dart' show RecordOverrides;

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
  // The ⌘⌥5 capture-to-pin session — toolbar shows the pin icon + caption.
  final bool pinMode;
  // Live-select (recording) session: transparent base, crop-select only,
  // confirm starts a recording. [liveLoupeSample] feeds the loupe live pixels.
  final bool recordMode;
  final Future<Uint8List?> Function(int x, int y, int span)? liveLoupeSample;
  // One-shot per-recording overrides shown in the record-mode toolbar.
  final RecordOverrides? recordOverrides;
  // Capture layer stack caption below the toolbar (null = hidden); accent
  // marks the transient "top layer was replaced" notice.
  final String? layerCaption;
  final bool layerAccent;
  // Presentation-only: render base + drawables, no interactive chrome, never
  // active. Used to show the screenshot session beneath an active record-select.
  final bool presentationOnly;
  // Precise AX element snap (Advanced experiment). Non-null only on the frozen
  // screenshot session when the setting is on; null on the record-select picker.
  final Future<ElementSnap?> Function(Offset displayLocalPoint, {int walk})?
      elementSnapAt;

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
    this.pinMode = false,
    this.recordMode = false,
    this.liveLoupeSample,
    this.recordOverrides,
    this.layerCaption,
    this.layerAccent = false,
    this.presentationOnly = false,
    this.elementSnapAt,
  });

  @override
  Widget build(BuildContext context) {
    return EditorCore(
      controller: controller,
      editorBindings: editorBindings,
      loupe: loupe,
      hud: hud,
      pinMode: pinMode,
      recordMode: recordMode,
      recordOverrides: recordOverrides,
      layerCaption: layerCaption,
      layerAccent: layerAccent,
      presentationOnly: presentationOnly,
      host: OverlayEditorHost(
        display: display,
        frozen: frozenImage,
        activeSignal: activeSignal,
        rightClickExits: rightClickExits,
        onExport: onExport,
        onCancel: onCancel,
        cursorImage: cursorImage,
        cursorTopLeft: cursorTopLeft,
        liveSelect: recordMode,
        liveLoupeSample: liveLoupeSample,
        elementSnapAt: elementSnapAt,
      ),
    );
  }
}
