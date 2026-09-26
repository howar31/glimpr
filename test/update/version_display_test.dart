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

  test('versionCore drops the build suffix and the leading v', () {
    expect(versionCore('1.20.0 (33)'), '1.20.0');
    expect(versionCore('v1.20.0'), '1.20.0');
    expect(versionCore('V1.20.0 (2)'), '1.20.0');
    expect(versionCore('  1.2.3  '), '1.2.3');
    expect(versionCore(''), '');
  });
}
