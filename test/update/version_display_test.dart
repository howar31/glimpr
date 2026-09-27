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

  test('versionCore also drops a prerelease suffix', () {
    expect(versionCore('1.21.1-rc.1 (35)'), '1.21.1');
    expect(versionCore('v1.21.1-rc.1'), '1.21.1');
  });

  test('versionPrerelease is the suffix after the core, empty for stable', () {
    expect(versionPrerelease('1.21.1-rc.1 (35)'), 'rc.1');
    expect(versionPrerelease('v1.21.1-rc.2'), 'rc.2');
    expect(versionPrerelease('1.21.1 (35)'), '');
    expect(versionPrerelease(''), '');
  });
}
