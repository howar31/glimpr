import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/overlay_app.dart';
import 'package:glimpr/overlay/overlay_canvas.dart';
import 'package:glimpr/capture/captured_display.dart';

CapturedDisplay tinyDisplay() {
  // 1x1 transparent PNG.
  final png = Uint8List.fromList(<int>[
    137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,6,0,0,0,
    31,21,196,137,0,0,0,13,73,68,65,84,120,156,99,0,1,0,0,5,0,1,13,10,45,180,
    0,0,0,0,73,69,78,68,174,66,96,130,
  ]);
  return CapturedDisplay(
    displayId: 1, pngBytes: png, left: 0, top: 0, width: 200, height: 100,
    scaleFactor: 2.0, isCursorDisplay: true,
  );
}

void main() {
  testWidgets('OverlayApp is transparent and shows nothing when idle', (tester) async {
    await tester.pumpWidget(const OverlayApp());
    // Idle: no frozen image, fully transparent (no opaque Scaffold background).
    expect(find.byType(Image), findsNothing);
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.debugShowCheckedModeBanner, isFalse);
  });

  testWidgets('OverlayCanvas reports selection on drag and Esc cancels', (tester) async {
    Rect? committed; var cancelled = false;
    await tester.pumpWidget(MaterialApp(
      home: OverlayCanvas(
        display: tinyDisplay(),
        onCommit: (r) => committed = r,
        onCancel: () => cancelled = true,
      ),
    ));
    await tester.pump(); // allow the decoded image to resolve

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(80, 60));
    await gesture.up();
    await tester.pump();
    expect(committed, isNotNull);
    expect(committed!.width, greaterThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(cancelled, isTrue);
  });
}
