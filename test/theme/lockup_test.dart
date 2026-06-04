import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/theme/glimpr_theme.dart';
import 'package:glimpr/theme/glimpr_controls.dart';

Widget _host(GlimprTokens t, Widget child) => GlimprTheme(
      tokens: t,
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    );

void main() {
  testWidgets('Lockup shows the mark beside the G + limpr wordmark',
      (tester) async {
    await tester.pumpWidget(_host(GlimprTokens.dark, const Lockup()));

    expect(find.byType(GlimprMark), findsOneWidget);
    // Wordmark renders the gradient "G" and the solid "limpr" as separate spans.
    expect(find.text('G'), findsOneWidget);
    expect(find.text('limpr'), findsOneWidget);
  });

  testWidgets('Wordmark "limpr" uses the foreground token by default',
      (tester) async {
    await tester.pumpWidget(_host(GlimprTokens.light, const Wordmark(size: 20)));

    final rest = tester.widget<Text>(find.text('limpr'));
    expect(rest.style?.color, GlimprTokens.light.fg1);
  });

  test('the logo gradient is the cyan/blue/violet brand ramp, not the UI accent',
      () {
    expect(kGlimprLogoGradient.colors,
        const [Color(0xFF22D3EE), Color(0xFF3B82F6), Color(0xFFA78BFA)]);
    // It must stay distinct from the Aurora UI accent.
    expect(kGlimprLogoGradient.colors, isNot(GlimprTokens.accentGrad.colors));
  });
}
