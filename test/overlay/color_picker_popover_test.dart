import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/style_popovers.dart';

void main() {
  testWidgets('tapping a preset emits onChanged with that colour', (t) async {
    Color? changed;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ColorPickerPopover(
          color: const Color(0xFFFF3B30),
          recents: const [],
          onChanged: (c) => changed = c,
          onCommit: (_) {},
        ),
      ),
    ));
    await t.tap(find.byKey(const ValueKey('preset-0xFF007AFF')));
    await t.pump();
    expect(changed, const Color(0xFF007AFF));
  });

  testWidgets('typing a valid hex commits that colour', (t) async {
    Color? changed;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ColorPickerPopover(
          color: const Color(0xFFFF3B30),
          recents: const [],
          onChanged: (c) => changed = c,
          onCommit: (_) {},
        ),
      ),
    ));
    await t.enterText(find.byKey(const ValueKey('hex-field')), '#0000FF');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(changed, const Color(0xFF0000FF));
  });
}
