import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/widgets/key_cap_chips.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/theme/glimpr_theme.dart';

import '../support/localized_app.dart';

// KeyCap reads GlimprTheme.of(context), so the test widget is wrapped in a
// GlimprTheme ancestor (mirrors settings_app.dart's GlimprTheme provider).
Widget _wrap(Widget child) => localizedApp(
      GlimprTheme(
        tokens: GlimprTokens.dark,
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  testWidgets('renders a cap per modifier + key', (tester) async {
    const b = HotkeyBinding(
      physicalKey: PhysicalKeyboardKey.digit1,
      logicalKey: LogicalKeyboardKey.digit1,
      modifiers: {HotkeyModifier.meta, HotkeyModifier.alt},
    );
    await tester.pumpWidget(_wrap(const KeyCapChips(b)));
    expect(find.byType(KeyCap), findsNWidgets(3)); // ⌥ ⌘ 1
  });

  testWidgets('renders muted text (not a cap) when unbound', (tester) async {
    await tester.pumpWidget(_wrap(const KeyCapChips(null)));
    expect(find.byType(KeyCap), findsNothing); // no pressable-looking chip
    expect(find.text('None'), findsOneWidget); // default empty label
  });
}
