import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/overlay_app.dart';

void main() {
  testWidgets('OverlayApp is transparent and shows nothing when idle', (
    tester,
  ) async {
    await tester.pumpWidget(const OverlayApp());
    // Idle: no frozen image, fully transparent (no opaque Scaffold background).
    expect(find.byType(Image), findsNothing);
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.debugShowCheckedModeBanner, isFalse);
  });
}
