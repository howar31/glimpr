import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/loupe_config.dart';
import 'package:glimpr/output/flow.dart';
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

  test('snapElementMode round-trips and defaults false', () async {
    final s = Settings(FakeStore());
    expect(await s.getSnapElementMode(), isFalse);
    expect((await s.loadCapture()).snapElementMode, isFalse);
    await s.setSnapElementMode(true);
    expect(await s.getSnapElementMode(), isTrue);
    expect((await s.loadCapture()).snapElementMode, isTrue);
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
    expect(cap.flow, {FlowAction.copy, FlowAction.save});
    expect(cap.rightClickExits, isTrue);
    expect(cap.filenameTemplate, '%app_%title_%Y-%m-%d_%H-%M-%S');
    expect(cap.subfolderPattern, '%Y/%Y-%m/%Y-%m-%d');
  });

  test('subfolder pattern defaults, round-trips, and allows empty', () async {
    final s = Settings(FakeStore());
    expect(await s.getSubfolderPattern(), '%Y/%Y-%m/%Y-%m-%d');
    await s.setSubfolderPattern('%Y');
    expect(await s.getSubfolderPattern(), '%Y');
    // Empty is VALID (= no subfolder); unlike the filename it is not coalesced.
    await s.setSubfolderPattern('');
    expect(await s.getSubfolderPattern(), '');
    expect((await s.loadCapture()).subfolderPattern, '');
  });

  test('name counter defaults to 0 and round-trips', () async {
    final s = Settings(FakeStore());
    expect(await s.getNameCounter(), 0);
    await s.setNameCounter(42);
    expect(await s.getNameCounter(), 42);
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
    await s.setAfterCaptureFlow(const <FlowAction>{});
    await s.setRightClickExits(false);
    final cap = await s.loadCapture();
    expect(cap.shutterSound, isFalse);
    expect(cap.completionSound, isFalse);
    expect(cap.flow, isEmpty);
    expect(cap.rightClickExits, isFalse);
  });

  test('after-capture flow defaults to copy+save and round-trips', () async {
    final s = Settings(FakeStore());
    expect(await s.getAfterCaptureFlow(), {FlowAction.copy, FlowAction.save});
    await s.setAfterCaptureFlow({FlowAction.save, FlowAction.showInFinder});
    expect(await s.getAfterCaptureFlow(),
        {FlowAction.save, FlowAction.showInFinder});
  });

  test('after-editor-done flow defaults to copy+save and round-trips',
      () async {
    final s = Settings(FakeStore());
    expect(await s.getAfterEditorDoneFlow(),
        {FlowAction.copy, FlowAction.save});
    await s.setAfterEditorDoneFlow({FlowAction.copyPath, FlowAction.save});
    expect(await s.getAfterEditorDoneFlow(),
        {FlowAction.copyPath, FlowAction.save});
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

  test('loupe info mode defaults to coords, round-trips, and feeds loadLoupe',
      () async {
    final s = Settings(FakeStore());
    expect(await s.getLoupeInfoMode(), LoupeInfoMode.coords);
    expect((await s.loadLoupe()).infoMode, LoupeInfoMode.coords);
    await s.setLoupeInfoMode(LoupeInfoMode.hidden);
    expect(await s.getLoupeInfoMode(), LoupeInfoMode.hidden);
    expect((await s.loadLoupe()).infoMode, LoupeInfoMode.hidden);
  });

  test('loupe info mode reads an unknown stored value as coords', () async {
    final store = FakeStore();
    await store.setString('loupe_info_mode', 'bogus');
    expect(await Settings(store).getLoupeInfoMode(), LoupeInfoMode.coords);
  });

  test('recording output-quality settings default and round-trip', () async {
    final s = Settings(FakeStore());
    // Defaults: high quality, 1920 long-side cap, GIF 15 fps, high GIF quality.
    expect(await s.getRecordVideoQuality(), RecordVideoQuality.high);
    expect(await s.getRecordMaxLongSide(), 1920);
    expect(await s.getRecordGifFps(), 15);
    final rec = await s.loadRecording();
    expect(rec.videoQuality, RecordVideoQuality.high);
    expect(rec.maxLongSide, 1920);
    expect(rec.gifFps, 15);

    await s.setRecordVideoQuality(RecordVideoQuality.low);
    await s.setRecordMaxLongSide(0); // native
    await s.setRecordGifFps(25);
    expect(await s.getRecordVideoQuality(), RecordVideoQuality.low);
    expect(await s.getRecordMaxLongSide(), 0);
    expect(await s.getRecordGifFps(), 25);
  });

  test('recording resolution + GIF fps clamp off-step values', () async {
    final s = Settings(FakeStore());
    // Off-step resolution clamps to the 1920 default; GIF fps clamps to 15.
    await s.setRecordMaxLongSide(999);
    expect(await s.getRecordMaxLongSide(), 1920);
    await s.setRecordGifFps(17);
    expect(await s.getRecordGifFps(), 15);
  });

  test('recording getters clamp an out-of-range stored value on read',
      () async {
    final store = FakeStore();
    // Simulate corrupt / out-of-range persisted values (bypassing setters).
    await store.setInt('record_max_long_side', 4096);
    await store.setInt('record_gif_fps', 99);
    final s = Settings(store);
    expect(await s.getRecordMaxLongSide(), 1920);
    expect(await s.getRecordGifFps(), 15);
  });
}
