import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings.dart';

void main() {
  test('resolveSaveDir maps a non-empty path, else null', () {
    expect(resolveSaveDir('/tmp/shots')?.path, '/tmp/shots');
    expect(resolveSaveDir(null), isNull);
    expect(resolveSaveDir(''), isNull);
  });
}
