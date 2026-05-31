import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/main.dart';

void main() {
  testWidgets('app builds and shows the Capture button', (tester) async {
    await tester.pumpWidget(const GlimprApp());
    expect(find.text('Capture'), findsOneWidget);
  });
}
