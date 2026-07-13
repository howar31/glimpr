import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/gif_editor_app.dart';
import 'package:glimpr/l10n/gen/app_localizations.dart';

import '../support/gif_fixture.dart';
import '../support/mock_channels.dart';

const _channel = MethodChannel('glimpr/gifEditor');

AppLocalizations get _en => lookupAppLocalizations(const Locale('en'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('landing shows the open card', (tester) async {
    mockMethodChannel(_channel);
    await tester.pumpWidget(const GifEditorApp());
    await tester.pump();
    expect(find.text(_en.gifEditorOpenGif), findsOneWidget);
    expect(find.text(_en.gifEditorOpenGifButton), findsOneWidget);
  });

  testWidgets('cancelled open panel keeps the landing', (tester) async {
    final calls = mockMethodChannel(_channel); // every call answers null
    await tester.pumpWidget(const GifEditorApp());
    await tester.pump();
    await tester.tap(find.text(_en.gifEditorOpenGifButton));
    await tester.pump();
    expect(calls.map((c) => c.method), contains('openPanel'));
    expect(find.text(_en.gifEditorOpenGifButton), findsOneWidget);
  });

  testWidgets('opening a GIF leaves the landing and shows the editor',
      (tester) async {
    // Async IO awaited directly in the test body parks under the fake zone
    // (nothing drains it) — the setup must run inside runAsync.
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('gifed_app')))!;
    final gifPath = '${dir.path}/in.gif';
    File(gifPath).writeAsBytesSync(twoFrameGifFixture());
    addTearDown(() => dir.deleteSync(recursive: true));

    mockMethodChannel(_channel, handler: (call) {
      if (call.method == 'openPanel') return gifPath;
      return null;
    });
    await tester.pumpWidget(const GifEditorApp());
    await tester.pump();
    await tester.tap(find.text(_en.gifEditorOpenGifButton));
    await tester.pump();
    // The open flow does real IO + engine decode; interleave real-async
    // turns with pumps until the editor mounts (the suite's pumpUntil
    // idiom — a single runAsync delay is not enough because the chain
    // needs frames pumped between its real-async segments).
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (find
            .byKey(const Key('gif-editor-canvas'))
            .evaluate()
            .isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(find.text(_en.gifEditorOpenGifButton), findsNothing);
    expect(find.byKey(const Key('gif-editor-canvas')), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
