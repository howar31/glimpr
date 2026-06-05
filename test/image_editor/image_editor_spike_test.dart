import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/image_editor_spike.dart';

void main() {
  testWidgets('ImageEditorSpikeApp builds and runs a repeating animation', (tester) async {
    await tester.pumpWidget(const ImageEditorSpikeApp());
    expect(find.byType(RotationTransition), findsAtLeastNWidgets(1));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
