import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/output/deliver.dart';

void main() {
  final bytes = Uint8List.fromList([1, 2, 3, 4]);

  test('all legs succeed: path set, copied, sound played, no errors', () async {
    Uint8List? clipBytes;
    var soundCalls = 0;
    final r = await deliverCapture(
      pngBytes: bytes,
      fileName: 'x.png',
      saveFn: (b, d, n) async => '/tmp/$n',
      clipboardFn: (b) async => clipBytes = b,
      soundFn: () async => soundCalls++,
    );
    expect(r.savedPath, '/tmp/x.png');
    expect(r.savedOk, isTrue);
    expect(r.copiedToClipboard, isTrue);
    expect(r.soundPlayed, isTrue);
    expect(r.errors, isEmpty);
    expect(clipBytes, same(bytes)); // same encoded bytes reused, not re-encoded
    expect(soundCalls, 1);
  });

  test('save failure is captured but clipboard and sound still run', () async {
    var copied = false, played = false;
    final r = await deliverCapture(
      pngBytes: bytes,
      saveFn: (b, d, n) async => throw const FileSystemException('disk full'),
      clipboardFn: (b) async => copied = true,
      soundFn: () async => played = true,
    );
    expect(r.savedOk, isFalse);
    expect(r.savedPath, isNull);
    expect(r.errors.containsKey('save'), isTrue);
    expect(r.copiedToClipboard, isTrue); // independent — not masked by save
    expect(copied, isTrue);
    expect(played, isTrue);
  });

  test(
    'clipboard failure is captured but save and sound still succeed',
    () async {
      final r = await deliverCapture(
        pngBytes: bytes,
        fileName: 'y.png',
        saveFn: (b, d, n) async => '/tmp/$n',
        clipboardFn: (b) async => throw StateError('no pasteboard'),
        soundFn: () async {},
      );
      expect(r.savedOk, isTrue);
      expect(r.copiedToClipboard, isFalse);
      expect(r.errors.containsKey('clipboard'), isTrue);
      expect(r.soundPlayed, isTrue);
    },
  );

  test(
    'sound failure is non-critical: save and clipboard still report ok',
    () async {
      final r = await deliverCapture(
        pngBytes: bytes,
        fileName: 'z.png',
        saveFn: (b, d, n) async => '/tmp/$n',
        clipboardFn: (b) async {},
        soundFn: () async => throw Exception('no audio'),
      );
      expect(r.savedOk, isTrue);
      expect(r.copiedToClipboard, isTrue);
      expect(r.soundPlayed, isFalse);
      expect(r.errors.containsKey('sound'), isTrue);
    },
  );

  test('saveToFile=false skips the save leg without recording an error', () async {
    var saveCalls = 0;
    final r = await deliverCapture(
      pngBytes: bytes,
      saveFn: (b, d, n) async {
        saveCalls++;
        return '/tmp/$n';
      },
      clipboardFn: (b) async {},
      soundFn: () async {},
      saveToFile: false,
    );
    expect(saveCalls, 0); // leg not invoked
    expect(r.savedOk, isFalse);
    expect(r.savedPath, isNull);
    expect(r.errors.containsKey('save'), isFalse); // skipped, not failed
    expect(r.copiedToClipboard, isTrue);
  });

  test('copyToClipboard=false skips the clipboard leg without an error', () async {
    var clipCalls = 0;
    final r = await deliverCapture(
      pngBytes: bytes,
      saveFn: (b, d, n) async => '/tmp/$n',
      clipboardFn: (b) async => clipCalls++,
      soundFn: () async {},
      copyToClipboard: false,
    );
    expect(clipCalls, 0); // leg not invoked
    expect(r.copiedToClipboard, isFalse);
    expect(r.errors.containsKey('clipboard'), isFalse); // skipped, not failed
    expect(r.savedOk, isTrue);
  });
}
