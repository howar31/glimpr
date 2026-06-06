import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_store.dart';

/// In-memory store so the settings logic is tested without the platform plugin.
class FakeStore implements SettingsStore {
  final Map<String, Object> _m = {};
  @override
  Future<String?> getString(String key) async => _m[key] as String?;
  @override
  Future<void> setString(String key, String value) async => _m[key] = value;
  @override
  Future<bool?> getBool(String key) async => _m[key] as bool?;
  @override
  Future<void> setBool(String key, bool value) async => _m[key] = value;
  @override
  Future<int?> getInt(String key) async => _m[key] as int?;
  @override
  Future<void> setInt(String key, int value) async => _m[key] = value;
  @override
  Future<void> remove(String key) async => _m.remove(key);
}

void main() {
  test('save directory round-trips and clears', () async {
    final s = Settings(FakeStore());
    expect(await s.getSaveDirectory(), isNull);
    await s.setSaveDirectory('/tmp/shots');
    expect(await s.getSaveDirectory(), '/tmp/shots');
    await s.clearSaveDirectory();
    expect(await s.getSaveDirectory(), isNull);
  });

  test('loadCapture defaults reproduce the original behaviour', () async {
    final cap = await Settings(FakeStore()).loadCapture();
    expect(cap.saveDir, isNull);
    expect(cap.format, ImageFormat.png);
    expect(cap.isJpeg, isFalse);
    expect(cap.fileExtension, 'png');
    expect(cap.jpegQuality, 90);
    expect(cap.shutterSound, isTrue);
    expect(cap.completionSound, isTrue);
    expect(cap.saveToFile, isTrue);
    expect(cap.copyToClipboard, isTrue);
    expect(cap.rightClickExits, isTrue);
  });

  test('format + quality round-trip and feed the snapshot', () async {
    final s = Settings(FakeStore());
    await s.setFormat(ImageFormat.jpeg);
    await s.setJpegQuality(60);
    expect(await s.getFormat(), ImageFormat.jpeg);
    final cap = await s.loadCapture();
    expect(cap.isJpeg, isTrue);
    expect(cap.fileExtension, 'jpg');
    expect(cap.jpegQuality, 60);
  });

  test('jpeg quality is clamped to 1..100', () async {
    final s = Settings(FakeStore());
    await s.setJpegQuality(999);
    expect(await s.getJpegQuality(), 100);
    await s.setJpegQuality(0);
    expect(await s.getJpegQuality(), 1);
  });

  test('sound + destination toggles round-trip into the snapshot', () async {
    final s = Settings(FakeStore());
    await s.setShutterSound(false);
    await s.setCompletionSound(false);
    await s.setSaveToFile(false);
    await s.setCopyToClipboard(false);
    await s.setRightClickExits(false);
    final cap = await s.loadCapture();
    expect(cap.shutterSound, isFalse);
    expect(cap.completionSound, isFalse);
    expect(cap.saveToFile, isFalse);
    expect(cap.copyToClipboard, isFalse);
    expect(cap.rightClickExits, isFalse);
  });

  test('loadLoupe defaults to span 12 / zoom 8 when unset', () async {
    final l = await Settings(FakeStore()).loadLoupe();
    expect(l.span, 12);
    expect(l.zoom, 8);
    expect(l.box, 96.0);
  });

  test('loupe span + zoom round-trip into loadLoupe', () async {
    final s = Settings(FakeStore());
    await s.setLoupeSpan(7);
    await s.setLoupeZoom(12);
    expect(await s.getLoupeSpan(), 7);
    expect(await s.getLoupeZoom(), 12);
    final l = await s.loadLoupe();
    expect(l.span, 7);
    expect(l.zoom, 12);
  });

  test('loupe span is clamped to 5..20 on write', () async {
    final s = Settings(FakeStore());
    await s.setLoupeSpan(99);
    expect(await s.getLoupeSpan(), 20);
    await s.setLoupeSpan(1);
    expect(await s.getLoupeSpan(), 5);
  });

  test('loupe zoom is clamped to 4..16 on write', () async {
    final s = Settings(FakeStore());
    await s.setLoupeZoom(99);
    expect(await s.getLoupeZoom(), 16);
    await s.setLoupeZoom(1);
    expect(await s.getLoupeZoom(), 4);
  });

  test('loupe getters clamp an out-of-range stored value on read', () async {
    final store = FakeStore();
    // Simulate a corrupt / out-of-range persisted value (bypassing the setter).
    await store.setInt('loupe_span', 999);
    await store.setInt('loupe_zoom', 0);
    final s = Settings(store);
    expect(await s.getLoupeSpan(), 20);
    expect(await s.getLoupeZoom(), 4);
  });
}
