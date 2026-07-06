import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart' show SnapWindow;
import 'package:glimpr/capture/element_snap.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/editor/editor_core.dart';
import 'package:glimpr/editor/editor_host.dart';
import 'package:glimpr/editor/hud_config.dart';
import 'package:glimpr/editor/loupe_config.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';

import 'localized_app.dart';

/// Records every native-cursor call EditorCore pushes, so tests can assert the
/// hide/unhide balance, the drawing-lock pairing, and arrow-nudge warps.
class RecordingCursorController implements EditorCursorController {
  final hiddenCalls = <bool>[];
  final drawingLockCalls = <bool>[];
  final warpCalls = <Offset>[];

  @override
  void setHidden(bool hidden) => hiddenCalls.add(hidden);
  @override
  void setDrawingLock(bool locked) => drawingLockCalls.add(locked);
  @override
  void warp(double globalX, double globalY) =>
      warpCalls.add(Offset(globalX, globalY));
}

/// In-memory [EditorHost] for EditorCore widget tests. Defaults mirror the
/// capture overlay (full-screen 1:1, no trim); flip [viewportInteractive] +
/// [cropTrims] for the image-editor shape. Records exports / cancels / settings
/// opens / persisted loupe modes so tests assert host traffic, not internals.
class FakeEditorHost extends EditorHost {
  FakeEditorHost({
    required this.baseImage,
    this.size = const Size(800, 600),
    this.pixelScale = 1.0,
    this.cursorSeed,
    this.startsActive = true,
    this.hostId = 7,
    this.globalOrigin = Offset.zero,
    this.snapWindows = const [],
    this.elementSnapAt,
    this.rightClickExits = true,
    this.showFloatingToolbar = false,
    this.viewportInteractive = false,
    this.cropTrims = false,
    this.liveSelect = false,
    ValueNotifier<({int id, Offset cursor})>? activeSignal,
    RecordingCursorController? cursor,
  })  : cursor = cursor ?? RecordingCursorController(),
        activeSignalNotifier = activeSignal ??
            ValueNotifier((
              // Default signal agrees with startsActive: our id when active,
              // another display's id when not.
              id: startsActive ? hostId : hostId + 1,
              cursor: Offset.zero,
            ));

  @override
  final ui.Image baseImage;
  @override
  final Size size;
  @override
  final double pixelScale;
  @override
  final Offset? cursorSeed;
  @override
  final bool startsActive;
  @override
  final int hostId;
  @override
  final Offset globalOrigin;
  @override
  final List<SnapWindow> snapWindows;
  @override
  final Future<ElementSnap?> Function(Offset displayLocalPoint, {int walk})?
      elementSnapAt;
  @override
  final bool rightClickExits;
  @override
  final bool showFloatingToolbar;
  @override
  final bool viewportInteractive;
  @override
  final bool cropTrims;
  @override
  final bool liveSelect;
  @override
  final RecordingCursorController cursor;

  /// Poke `.value` to drive the cross-display active handoff in a test.
  final ValueNotifier<({int id, Offset cursor})> activeSignalNotifier;
  @override
  ValueListenable<({int id, Offset cursor})> get activeSignal =>
      activeSignalNotifier;

  /// Every onExport call, in order (rect == null means whole display).
  final exports = <({Rect? rect, SnapWindow? window})>[];
  int cancelCount = 0;
  int openSettingsCount = 0;
  final persistedLoupeModes = <LoupeInfoMode>[];

  @override
  Future<void> onExport(Rect? selectionLogical, SnapWindow? window) async {
    exports.add((rect: selectionLogical, window: window));
  }

  @override
  void onCancel() => cancelCount++;

  @override
  void openSettings() => openSettingsCount++;

  @override
  void persistLoupeInfoMode(LoupeInfoMode mode) =>
      persistedLoupeModes.add(mode);
}

/// Builds a solid-fill RGBA test image. MUST run outside testWidgets' fake-async
/// zone (call from setUpAll or a plain async test): decode callbacks never fire
/// inside FakeAsync, and picture.toImage would hang there outright.
/// (Named to avoid flutter_test's own createTestImage.)
Future<ui.Image> makeBaseImage(int width, int height) {
  final done = Completer<ui.Image>();
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = 0x33; // R
    pixels[i + 1] = 0x66; // G
    pixels[i + 2] = 0x99; // B
    pixels[i + 3] = 0xFF; // A
  }
  ui.decodeImageFromPixels(
      pixels, width, height, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

/// Pumps an [EditorCore] wired to [host] inside the localized app shell, with
/// the test view sized to [view] at devicePixelRatio 1.0 so gesture coords ==
/// logical canvas coords (for the default full-view overlay host). Marching
/// ants default OFF so pumpAndSettle terminates. Returns the live controller.
Future<EditorController> pumpEditorCore(
  WidgetTester tester,
  FakeEditorHost host, {
  EditorController? controller,
  Map<String, HotkeyBinding?>? bindings,
  LoupeConfig loupe = const LoupeConfig(),
  HudConfig hud = const HudConfig(marchingAnts: false),
  bool pinMode = false,
  bool recordMode = false,
  bool presentationOnly = false,
  Size view = const Size(800, 600),
}) async {
  tester.view.physicalSize = view;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = controller ?? EditorController();
  if (controller == null) addTearDown(c.dispose);
  await tester.pumpWidget(
    localizedApp(
      EditorCore(
        controller: c,
        editorBindings: bindings ?? kDefaultBindings,
        host: host,
        loupe: loupe,
        hud: hud,
        pinMode: pinMode,
        recordMode: recordMode,
        presentationOnly: presentationOnly,
      ),
    ),
  );
  // Settle the post-frame focus request so key events reach the editor.
  await tester.pump();
  return c;
}
