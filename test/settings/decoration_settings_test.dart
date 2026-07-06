import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/capture_kind.dart';
import 'package:glimpr/settings/settings.dart';

import '../support/fake_store.dart';

void main() {
  test('defaults: every scenario off, white fill', () {
    const s = CaptureSettings();
    for (final k in CaptureKind.values) {
      expect(s.decorateFor(k), false);
    }
    expect(s.decorationJpegFill, 0xFFFFFFFF);
  });

  test('decorateFor maps each kind to its flag', () {
    const s = CaptureSettings(
      decorateSnap: true,
      decorateCrop: false,
      decorateWindow: true,
      decorateDisplay: false,
      decorateLastRegion: true,
    );
    expect(s.decorateFor(CaptureKind.overlaySnap), true);
    expect(s.decorateFor(CaptureKind.overlayCrop), false);
    expect(s.decorateFor(CaptureKind.focusedWindow), true);
    expect(s.decorateFor(CaptureKind.display), false);
    expect(s.decorateFor(CaptureKind.lastRegion), true);
    expect(s.decorateFor(CaptureKind.overlayWholeDisplay), false);
  });

  test('captureCursor defaults false and round-trips', () async {
    expect(const CaptureSettings().captureCursor, false);
    final settings = Settings(FakeStore());
    await settings.setCaptureCursor(true);
    expect((await settings.loadCapture()).captureCursor, true);
  });

  test('Settings round-trips the flags + fill into a snapshot', () async {
    final settings = Settings(FakeStore());
    await settings.setDecorateSnap(true);
    await settings.setDecorateLastRegion(true);
    await settings.setDecorationJpegFill(0xFF202020);
    final cap = await settings.loadCapture();
    expect(cap.decorateFor(CaptureKind.overlaySnap), true);
    expect(cap.decorateFor(CaptureKind.lastRegion), true);
    expect(cap.decorateFor(CaptureKind.display), false);
    expect(cap.decorationJpegFill, 0xFF202020);
  });
}
