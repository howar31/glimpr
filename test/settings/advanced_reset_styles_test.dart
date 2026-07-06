import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/tool_style_store.dart';

import '../support/fake_store.dart';

void main() {
  test('resetAll empties a populated store', () async {
    final store = FakeStore();
    await store.setString('tool_styles', '{"arrow":{"color":1,"strokeWidth":2.0,"fontSize":3.0}}');
    await ToolStyleStore(store).resetAll();
    expect(await store.getString('tool_styles'), isNull);
  });
}
