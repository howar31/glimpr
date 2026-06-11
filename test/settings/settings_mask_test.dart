import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings_mask.dart';

// The mask must follow the system appearance like the rest of the chrome
// (toolbar/popovers/confirm dialog): a navy card + light text in dark mode,
// a near-white card + slate text in light mode. The dim scrim stays the same
// dark veil in both modes (matching the confirm-dialog barrier).
void main() {
  Future<void> pumpMask(WidgetTester tester, Brightness brightness) async {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      const MaterialApp(home: Stack(children: [SettingsMask()])),
    );
  }

  BoxDecoration cardDecoration(WidgetTester tester) {
    final card = tester.widget<Container>(
      find.descendant(
        of: find.byType(SettingsMask),
        matching: find.byType(Container),
      ),
    );
    return card.decoration! as BoxDecoration;
  }

  Color textColor(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!.color!;

  testWidgets('dark mode keeps the navy card and light text', (tester) async {
    await pumpMask(tester, Brightness.dark);

    final scrim = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(SettingsMask),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(scrim.color, const Color(0x99000000));

    final deco = cardDecoration(tester);
    expect(deco.color, const Color(0xF21A2138));
    expect(deco.border!.top.color, const Color(0x33FFFFFF));
    expect(textColor(tester, 'Settings open'), const Color(0xFFFFFFFF));
    expect(
      textColor(tester, 'Close the Settings window to continue.'),
      const Color(0xCCFFFFFF),
    );
  });

  testWidgets('light mode swaps to the light card and dark text',
      (tester) async {
    await pumpMask(tester, Brightness.light);

    final scrim = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(SettingsMask),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(scrim.color, const Color(0x99000000)); // veil stays dark

    final deco = cardDecoration(tester);
    expect(deco.color, const Color(0xF2EEF2F7));
    expect(deco.border!.top.color, const Color(0x66FFFFFF));
    expect(textColor(tester, 'Settings open'), const Color(0xFF14223B));
    expect(
      textColor(tester, 'Close the Settings window to continue.'),
      const Color(0xFF475569),
    );
  });
}
