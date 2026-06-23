import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr_pro/glimpr_pro.dart';

void main() {
  // Build-agnostic: holds for the OSS stub (always locked) AND the real package
  // with no license installed (the test environment has no glimpr/license host).
  group('Pro gate — no license installed', () {
    test('every Pro feature is locked before any license is installed', () {
      for (final feature in Feature.values) {
        expect(ProRuntime.gate.state(feature), FeatureState.locked);
      }
    });

    test('install() completes and leaves every feature locked', () async {
      await ProRuntime.install();
      for (final feature in Feature.values) {
        expect(ProRuntime.gate.state(feature), FeatureState.locked);
      }
    });
  });
}
