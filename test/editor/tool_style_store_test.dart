import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/editor/tool_style_store.dart';

import '../support/fake_store.dart';

void main() {
  test('empty store loads as empty map', () async {
    final s = ToolStyleStore(FakeStore());
    expect(await s.load(), isEmpty);
  });

  test('save then load round-trips the per-tool map', () async {
    final store = FakeStore();
    final s = ToolStyleStore(store);
    final map = {
      ToolKind.rectangle: const DrawStyle(color: Color(0xFF00FF00), strokeWidth: 8),
      ToolKind.text: const DrawStyle(fontSize: 30, fontFamily: 'PingFang TC'),
    };
    await s.save(map);
    final back = await s.load();
    expect(back[ToolKind.rectangle], map[ToolKind.rectangle]);
    expect(back[ToolKind.text], map[ToolKind.text]);
  });

  test('resetAll clears persisted styles', () async {
    final s = ToolStyleStore(FakeStore());
    await s.save({ToolKind.arrow: const DrawStyle(strokeWidth: 12)});
    await s.resetAll();
    expect(await s.load(), isEmpty);
  });

  test('corrupt JSON loads as empty (no throw)', () async {
    final store = FakeStore();
    await store.setString('tool_styles', '{not json');
    expect(await ToolStyleStore(store).load(), isEmpty);
  });

  test('recent colours persist MRU + cap', () async {
    final s = ToolStyleStore(FakeStore());
    expect(await s.loadRecentColors(), isEmpty);
    await s.pushRecentColor(0xFFAA0000);
    await s.pushRecentColor(0xFF00BB00);
    await s.pushRecentColor(0xFFAA0000); // dup -> front
    expect(await s.loadRecentColors(), [0xFFAA0000, 0xFF00BB00]);
  });
}
