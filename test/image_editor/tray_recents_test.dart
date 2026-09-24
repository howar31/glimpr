import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/tray_recents.dart';
import '../support/fake_store.dart';
import '../support/mock_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glimpr/role.test');

  test('refresh reloads, prunes missing files and pushes the list', () async {
    final store = FakeStore({
      'recent_images': jsonEncode([r'C:\keep.png', r'C:\gone.png']),
    });
    final pushed = mockMethodChannel(channel);
    var reloaded = 0;
    final tr = TrayRecents(
      store: store,
      channel: channel,
      exists: (p) => p.endsWith('keep.png'),
      reload: () async => reloaded++,
    );
    expect(await tr.refresh(), [r'C:\keep.png']);
    expect(reloaded, 1);
    expect(pushed.map((c) => c.method), ['setRecentImages']);
    expect(pushed.single.arguments, [r'C:\keep.png']);
  });

  test('clear empties the store and pushes an empty list', () async {
    final store = FakeStore({'recent_images': jsonEncode([r'C:\a.png'])});
    final pushed = mockMethodChannel(channel);
    final tr = TrayRecents(
      store: store,
      channel: channel,
      exists: (_) => true,
      reload: () async {},
    );
    await tr.clear();
    expect(await store.getString('recent_images'), isNull);
    expect(pushed.single.method, 'setRecentImages');
    expect(pushed.single.arguments, isEmpty);
  });

  test('a broken store or a dead channel never throws', () async {
    final store = FakeStore({'recent_images': 'not json'});
    final tr = TrayRecents(
      store: store,
      channel: channel, // no mock handler: invokeMethod throws
      exists: (_) => true,
      reload: () async => throw StateError('no prefs'),
    );
    expect(await tr.refresh(), isEmpty);
    await tr.clear();
  });
}
