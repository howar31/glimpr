import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/capture_kind.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_store.dart';

/// In-memory SettingsStore for tests.
class _MapStore implements SettingsStore {
  final _m = <String, Object>{};
  @override
  Future<bool?> getBool(String k) async => _m[k] as bool?;
  @override
  Future<void> setBool(String k, bool v) async => _m[k] = v;
  @override
  Future<int?> getInt(String k) async => _m[k] as int?;
  @override
  Future<void> setInt(String k, int v) async => _m[k] = v;
  @override
  Future<String?> getString(String k) async => _m[k] as String?;
  @override
  Future<void> setString(String k, String v) async => _m[k] = v;
  @override
  Future<void> remove(String k) async => _m.remove(k);
}

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

  test('Settings round-trips the flags + fill into a snapshot', () async {
    final settings = Settings(_MapStore());
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
