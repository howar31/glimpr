import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/image_editor_app.dart';

void main() {
  testWidgets('ImageEditorApp renders the Aurora landing state', (tester) async {
    // Store prefetch in initState uses try/catch — must not throw under the
    // test binding (no platform channel), so the landing build stays stable.
    await tester.pumpWidget(const ImageEditorApp());
    await tester.pump(); // settle pending microtasks

    // The Open button (its accent label) and the static hint are both present.
    expect(find.text('Open Image…'), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.textContaining('Annotate'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
