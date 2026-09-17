import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/update/release_notes.dart';

const _body = '''
Lead sentence stays on GitHub.

## What's new
<!-- glimpr:notes lang=en -->
- **Download progress**: percent and MB while the update downloads.
- **Stalled downloads fail** instead of hanging.
- A plain bullet with `code` and **bold** inside.
<!-- /glimpr:notes -->

<details><summary>繁體中文</summary>
<!-- glimpr:notes lang=zh -->
- **下載進度**：更新下載時顯示百分比與 MB。
- **停滯的下載會失敗**，不再永遠卡住。
<!-- /glimpr:notes -->
</details>

## Notes
- Not part of any block.
''';

void main() {
  test('picks the block for the wanted language', () {
    final zh = parseReleaseNotes(_body, 'zh')!;
    expect(zh, hasLength(2));
    expect(zh.first.title, '下載進度');
    expect(zh.first.detail, '更新下載時顯示百分比與 MB。');
    expect(zh.last.title, '停滯的下載會失敗');
    expect(zh.last.detail, '，不再永遠卡住。');
  });

  test('region suffixes are ignored', () {
    expect(parseReleaseNotes(_body, 'zh-Hant-TW')!.first.title, '下載進度');
    expect(parseReleaseNotes(_body, 'en_US')!.first.title,
        'Download progress');
  });

  test('falls back to English and strips inline markers', () {
    final ja = parseReleaseNotes(_body, 'ja')!;
    expect(ja, hasLength(3));
    expect(ja[0].title, 'Download progress');
    expect(ja[0].detail, 'percent and MB while the update downloads.');
    expect(ja[1].title, 'Stalled downloads fail');
    expect(ja[1].detail, 'instead of hanging.');
    expect(ja[2].title, 'A plain bullet with code and bold inside.');
    expect(ja[2].detail, '');
  });

  test('bullets outside any block are never used', () {
    final en = parseReleaseNotes(_body, 'en')!;
    expect(en.map((i) => i.title), isNot(contains('Not part of any block.')));
  });

  test('no block, empty block, or empty body yields null', () {
    expect(parseReleaseNotes('## What\'s new\n- **A**: b', 'en'), isNull);
    expect(
        parseReleaseNotes(
            '<!-- glimpr:notes lang=en -->\n\n<!-- /glimpr:notes -->', 'en'),
        isNull);
    expect(parseReleaseNotes('', 'en'), isNull);
    // An unterminated block is ignored rather than swallowing the rest.
    expect(parseReleaseNotes('<!-- glimpr:notes lang=en -->\n- **A**: b', 'en'),
        isNull);
  });
}
