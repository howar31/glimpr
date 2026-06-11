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

  // The HUD pill is chrome, so it follows the system appearance: dark body +
  // light text in dark mode, near-white body + slate text in light mode.
  testWidgets('HUD pill follows the system appearance', (tester) async {
    Future<void> pump(Brightness b) async {
      tester.platformDispatcher.platformBrightnessTestValue = b;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LoupeReadout(x: 10, y: 20))),
      );
    }

    BoxDecoration pillDecoration() {
      final pill = tester.widget<Container>(
        find.descendant(
          of: find.byType(LoupeReadout),
          matching: find.byType(Container),
        ),
      );
      return pill.decoration! as BoxDecoration;
    }

    await pump(Brightness.dark);
    expect(pillDecoration().color, const Color(0xF2202020));
    expect(
      tester.widget<Text>(find.text('10, 20')).style!.color,
      const Color(0xFFFFFFFF),
    );

    await pump(Brightness.light);
    expect(pillDecoration().color, const Color(0xFAFFFFFF));
    expect(
      tester.widget<Text>(find.text('10, 20')).style!.color,
      const Color(0xFF14223B),
    );
  });
}
