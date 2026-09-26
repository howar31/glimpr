import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/update/version_display.dart';

void main() {
  test('displayVersion gives every form the same leading v', () {
    expect(displayVersion('1.18.0 (31)'), 'v1.18.0 (31)');
    expect(displayVersion('v1.18.0'), 'v1.18.0');
    expect(displayVersion('V1.18.0'), 'v1.18.0');
    expect(displayVersion(' 1.18.0 '), 'v1.18.0');
    expect(displayVersion(''), '');
  });
}
