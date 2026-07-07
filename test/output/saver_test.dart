import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/output/saver.dart';

void main() {
  test(
    'creates the folder if missing and writes the bytes, returning the path',
    () async {
      final tmp = await Directory.systemTemp.createTemp('glimpr_test_');
      final dir = Directory('${tmp.path}/Screenshots');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final path = await saveBytes(dir: dir, fileName: 'a.png', bytes: bytes);
      expect(File(path).existsSync(), isTrue);
      expect(await File(path).readAsBytes(), bytes);
      // Separator-agnostic: the box (Windows) joins with backslashes.
      expect(path.endsWith('Screenshots${Platform.pathSeparator}a.png'),
          isTrue);
      await tmp.delete(recursive: true);
    },
  );
  test('does not overwrite an existing file (adds counter)', () async {
    final tmp = await Directory.systemTemp.createTemp('glimpr_test_');
    final dir = Directory(tmp.path);
    final bytes = Uint8List.fromList([9]);
    final p1 = await saveBytes(dir: dir, fileName: 'b.png', bytes: bytes);
    final p2 = await saveBytes(dir: dir, fileName: 'b.png', bytes: bytes);
    expect(p1.endsWith('${Platform.pathSeparator}b.png'), isTrue);
    expect(p2.endsWith('${Platform.pathSeparator}b_001.png'), isTrue);
    await tmp.delete(recursive: true);
  });
}
