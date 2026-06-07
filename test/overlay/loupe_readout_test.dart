import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/crop_hud.dart';

void main() {
  testWidgets('LoupeReadout shows the current XY only', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LoupeReadout(x: 1024, y: 768))),
    );
    expect(find.text('1024, 768'), findsOneWidget);
    expect(find.textContaining('×'), findsNothing);
  });

  testWidgets('BoxSizeLabel shows only the size', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BoxSizeLabel(w: 234, h: 167))),
    );
    expect(find.text('234 × 167'), findsOneWidget);
    expect(find.textContaining(','), findsNothing);
  });

  testWidgets('StartCoordLabel shows the drag-start with a corner-pointing arrow', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StartCoordLabel(
            startX: 800,
            startY: 600,
            cornerLeft: true,
            cornerTop: true,
          ),
        ),
      ),
    );
    expect(find.text('800, 600'), findsOneWidget);
    // Start corner is top-left -> the pill sits outside it, arrow points inward.
    expect(find.byIcon(Icons.south_east), findsOneWidget);
  });
}
