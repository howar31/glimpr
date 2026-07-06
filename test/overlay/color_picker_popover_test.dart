import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/style_popovers.dart';

import '../support/localized_app.dart';

void main() {
  testWidgets('tapping a preset emits onChanged with that colour', (t) async {
    Color? changed;
    await t.pumpWidget(localizedApp(
      Scaffold(
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
    await t.pumpWidget(localizedApp(
      Scaffold(
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

  // The hex field + eyedropper button are chrome on the themed popover glass,
  // so they follow the system appearance like every other popover.
  testWidgets('hex field and eyedropper follow the system appearance',
      (t) async {
    Future<void> pump(Brightness b) async {
      t.platformDispatcher.platformBrightnessTestValue = b;
      addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
      await t.pumpWidget(localizedApp(
        Scaffold(
          body: ColorPickerPopover(
            color: const Color(0xFFFF3B30),
            recents: const [],
            onChanged: (_) {},
            onCommit: (_) {},
            onPickFromScreen: () {},
          ),
        ),
      ));
    }

    await pump(Brightness.dark);
    expect(
      t.widget<TextField>(find.byKey(const ValueKey('hex-field'))).style!.color,
      Colors.white,
    );
    expect(
      t.widget<Icon>(find.byIcon(Icons.colorize)).color,
      Colors.white70,
    );

    await pump(Brightness.light);
    expect(
      t.widget<TextField>(find.byKey(const ValueKey('hex-field'))).style!.color,
      const Color(0xFF14223B),
    );
    expect(
      t.widget<Icon>(find.byIcon(Icons.colorize)).color,
      const Color(0xFF475569),
    );
  });
}
