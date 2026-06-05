import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/image_editor_app.dart';

void main() {
  testWidgets('ImageEditorApp shows landing state with Open Image button',
      (tester) async {
    // Store prefetch in initState uses try/catch — must not throw under the
    // test binding (no platform channel), so the landing build stays stable.
    await tester.pumpWidget(const ImageEditorApp());
    await tester.pump(); // settle pending microtasks

    expect(find.text('Open Image…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
