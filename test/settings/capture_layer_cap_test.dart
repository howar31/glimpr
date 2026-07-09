import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings.dart';

import '../support/fake_store.dart';

void main() {
  test('capture layer cap defaults to 3 and clamps to 1-5', () async {
    final s = Settings(FakeStore());
    expect(await s.getCaptureLayerCap(), 3);
    await s.setCaptureLayerCap(3);
    expect(await s.getCaptureLayerCap(), 3);
    await s.setCaptureLayerCap(99);
    expect(await s.getCaptureLayerCap(), 5);
    await s.setCaptureLayerCap(0);
    expect(await s.getCaptureLayerCap(), 1);
  });
}
