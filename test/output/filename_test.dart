import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/output/filename.dart';

void main() {
  test('formats a locale-independent timestamp filename', () {
    expect(
      screenshotFilename(DateTime(2026, 5, 31, 9, 7, 3), 'png'),
      'Screenshot_2026-05-31_09-07-03.png',
    );
  });
  test('uses the given extension', () {
    expect(
      screenshotFilename(DateTime(2026, 1, 2, 3, 4, 5), 'jpg'),
      'Screenshot_2026-01-02_03-04-05.jpg',
    );
  });
  test('adds a _NNN counter when the base name is taken', () {
    bool exists(String n) =>
        n == 'Screenshot_2026-05-31_09-07-03.png' ||
        n == 'Screenshot_2026-05-31_09-07-03_001.png';
    expect(
      uniqueName('Screenshot_2026-05-31_09-07-03.png', exists: exists),
      'Screenshot_2026-05-31_09-07-03_002.png',
    );
  });
  test('returns the base name unchanged when free', () {
    expect(
      uniqueName('Screenshot_x.png', exists: (_) => false),
      'Screenshot_x.png',
    );
  });
}
