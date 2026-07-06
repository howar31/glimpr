import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings_mask.dart';
import 'package:glimpr/theme/glimpr_theme.dart';

import '../support/localized_app.dart';

// The mask must follow the system appearance like the rest of the chrome
// (toolbar/popovers/confirm dialog): a navy card + light text in dark mode,
// a near-white card + slate text in light mode. The dim scrim stays the same
// dark veil in both modes (matching the confirm-dialog barrier).
void main() {
  Future<void> pumpMask(WidgetTester tester, Brightness brightness) async {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      localizedApp(Stack(children: [SettingsMask()])),
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
    expect(scrim.color, GlimprTokens.scrim); // unified chrome dim, dark in both

    // Card = the shared HUD tier; text = the token fg ramp.
    final deco = cardDecoration(tester);
    expect(deco.color, GlimprTokens.dark.hudBg);
    expect(deco.border!.top.color, GlimprTokens.dark.hudBorder);
    expect(textColor(tester, 'Settings open'), GlimprTokens.dark.fg1);
    expect(
      textColor(tester, 'Close the Settings window to continue.'),
      GlimprTokens.dark.fg2,
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
    expect(scrim.color, GlimprTokens.scrim); // unified chrome dim, dark in both

    final deco = cardDecoration(tester);
    expect(deco.color, GlimprTokens.light.hudBg);
    expect(deco.border!.top.color, GlimprTokens.light.hudBorder);
    expect(textColor(tester, 'Settings open'), GlimprTokens.light.fg1);
    expect(
      textColor(tester, 'Close the Settings window to continue.'),
      GlimprTokens.light.fg2,
    );
  });
}
