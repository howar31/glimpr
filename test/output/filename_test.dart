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

  group('buildScreenshotName', () {
    final t = DateTime(2026, 6, 3, 14, 9, 5);

    test('default template uses the window name + date + time', () {
      expect(
        buildScreenshotName(
          template: defaultFilenameTemplate,
          t: t,
          windowTitle: 'Safari',
          ext: 'png',
        ),
        'Safari_2026-06-03_14-09-05.png',
      );
    });

    test('{window} falls back to the app name when there is no title', () {
      expect(
        buildScreenshotName(
          template: '{window}',
          t: t,
          windowTitle: '',
          appName: 'Finder',
          ext: 'png',
        ),
        'Finder.png',
      );
    });

    test('{app} is always the app name (not the window title)', () {
      expect(
        buildScreenshotName(
          template: '{app}_{time}',
          t: t,
          windowTitle: 'Inbox — Gmail',
          appName: 'Safari',
          ext: 'png',
        ),
        'Safari_14-09-05.png',
      );
    });

    test('an empty {window} leaves no dangling separator', () {
      expect(
        buildScreenshotName(
          template: '{window}_{date}_{time}',
          t: t,
          ext: 'png',
        ),
        '2026-06-03_14-09-05.png',
      );
    });

    test('filesystem-illegal characters are stripped', () {
      expect(
        buildScreenshotName(
          template: '{window}',
          t: t,
          windowTitle: 'a/b:c*?',
          ext: 'jpg',
        ),
        'abc.jpg',
      );
    });

    test('a template that resolves to empty falls back to the built-in name', () {
      expect(
        buildScreenshotName(template: '{window}', t: t, ext: 'png'),
        'Screenshot_2026-06-03_14-09-05.png',
      );
    });
  });
}
