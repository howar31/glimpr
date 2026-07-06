import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:glimpr/capture/capture_kind.dart';
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/image_editor/recent_images.dart';
import 'package:glimpr/output/flow.dart';
import 'package:glimpr/overlay/export.dart';
import 'package:glimpr/settings/settings.dart';

Future<ui.Image> _solidImage(int w, int h, ui.Color color) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = color,
  );
  return rec.endRecording().toImage(w, h);
}

CapturedDisplay _display({double w = 8, double h = 6, double scale = 2}) =>
    CapturedDisplay(
      displayId: 1,
      rawBytes: Uint8List(0),
      pixelWidth: (w * scale).round(),
      pixelHeight: (h * scale).round(),
      rowBytes: 0,
      left: 100,
      top: 50,
      width: w,
      height: h,
      scaleFactor: scale,
      isCursorDisplay: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    // Settings.instance is backed by SharedPreferencesAsync; route it to a
    // fresh in-memory platform so naming/counter/recents work without native.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    tmp = Directory.systemTemp.createTempSync('glimpr_export_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  CaptureSettings cap({
    Set<FlowAction> flow = const {FlowAction.save},
    String template = 'shot',
  }) =>
      CaptureSettings(
        saveDir: tmp,
        flow: flow,
        filenameTemplate: template,
        subfolderPattern: '',
      );

  test('exportAnnotated crops to the selection and saves a PNG', () async {
    final frozen = await _solidImage(16, 12, const ui.Color(0xFF3366CC));
    final result = await exportAnnotated(
      display: _display(),
      frozenImage: frozen,
      drawables: const [],
      selectionLogical: const Rect.fromLTWH(1, 1, 4, 3),
      cap: cap(),
      kind: CaptureKind.overlayCrop,
    );
    expect(result.savedOk, isTrue);
    expect(result.errors, isEmpty);
    final file = File(result.savedPath!);
    expect(file.existsSync(), isTrue);
    final decoded = await decodeImageFromList(await file.readAsBytes());
    // 4x3 logical at 2x scale = 8x6 native pixels.
    expect(decoded.width, 8);
    expect(decoded.height, 6);
  });

  test('exportAnnotated with no selection exports the whole display', () async {
    final frozen = await _solidImage(16, 12, const ui.Color(0xFF3366CC));
    final result = await exportAnnotated(
      display: _display(),
      frozenImage: frozen,
      drawables: const [],
      selectionLogical: null,
      cap: cap(),
      kind: CaptureKind.overlayCrop,
    );
    expect(result.savedOk, isTrue);
    final decoded = await decodeImageFromList(
        await File(result.savedPath!).readAsBytes());
    expect(decoded.width, 16);
    expect(decoded.height, 12);
  });

  test('exportAnnotated records the save into the shared recents store',
      () async {
    final frozen = await _solidImage(16, 12, const ui.Color(0xFF3366CC));
    final result = await exportAnnotated(
      display: _display(),
      frozenImage: frozen,
      drawables: const [],
      selectionLogical: null,
      cap: cap(),
      kind: CaptureKind.overlayCrop,
    );
    final recents = await RecentImagesStore(Settings.instance.store).load();
    expect(recents, contains(result.savedPath));
  });

  test('recordRecentCapture tolerates the absent native channel', () async {
    // notifyRecentChanged has no host in tests; the store write still counts.
    await recordRecentCapture('/tmp/some_capture.png');
    final recents = await RecentImagesStore(Settings.instance.store).load();
    expect(recents, contains('/tmp/some_capture.png'));
  });

  test('deliverEncodedCapture skips the clipboard write when preCopied',
      () async {
    // copy is in the flow but the native capture already wrote the clipboard
    // (Windows alsoCopy); the leg must report success without a channel call
    // (no clipboard host exists in tests, so a real write would fail).
    final result = await deliverEncodedCapture(
      capture: RegionCapture(
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        displayId: 1,
        rect: const Rect.fromLTWH(0, 0, 4, 3),
        displayOrigin: const Offset(100, 50),
        scaleFactor: 2,
        copiedNative: true,
      ),
      cap: cap(flow: {FlowAction.save, FlowAction.copy}),
      kind: CaptureKind.display,
    );
    expect(result.savedOk, isTrue);
    expect(result.copiedToClipboard, isTrue);
    expect(result.errors, isEmpty);
  });

  test('deliverEncodedCapture writes the HDR sibling beside the SDR file',
      () async {
    final hdr = Uint8List.fromList([9, 9, 9]);
    final result = await deliverEncodedCapture(
      capture: RegionCapture(
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        displayId: 1,
        rect: const Rect.fromLTWH(0, 0, 4, 3),
        displayOrigin: Offset.zero,
        scaleFactor: 2,
        hdrBytes: hdr,
        hdrExt: 'jxr',
      ),
      cap: cap(),
      kind: CaptureKind.display,
    );
    expect(result.savedOk, isTrue);
    final sdr = result.savedPath!;
    final sibling = File(
        '${sdr.substring(0, sdr.length - '.png'.length)}.jxr');
    expect(sibling.existsSync(), isTrue);
    expect(await sibling.readAsBytes(), hdr);
  });

  test('deliverWindowBytes saves and advances the %i counter when used',
      () async {
    final before = await Settings.instance.getNameCounter();
    final r1 = await deliverWindowBytes(
      bytes: Uint8List.fromList([1, 2, 3]),
      cap: cap(template: 'win_%i'),
    );
    final r2 = await deliverWindowBytes(
      bytes: Uint8List.fromList([4, 5, 6]),
      cap: cap(template: 'win_%i'),
    );
    expect(r1.savedOk, isTrue);
    expect(r2.savedOk, isTrue);
    expect(r1.savedPath, isNot(r2.savedPath));
    expect(await Settings.instance.getNameCounter(), before + 2);

    // A counter-free template leaves the counter untouched.
    await deliverWindowBytes(
      bytes: Uint8List.fromList([7, 8, 9]),
      cap: cap(template: 'plain'),
    );
    expect(await Settings.instance.getNameCounter(), before + 2);
  });

  test('deliverWindowBytes reports the preCopied clipboard as done', () async {
    final result = await deliverWindowBytes(
      bytes: Uint8List.fromList([1, 2, 3]),
      cap: cap(flow: {FlowAction.save, FlowAction.copy}),
      preCopied: true,
    );
    expect(result.copiedToClipboard, isTrue);
    expect(result.errors, isEmpty);
  });
}
