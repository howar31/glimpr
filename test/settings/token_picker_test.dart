import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/token_picker.dart';
import 'package:glimpr/theme/glimpr_theme.dart';

import '../support/localized_app.dart';

void main() {
  // Pumps a TokenInsertButton over [controller]; returns the last onChanged value
  // via [onChanged].
  Future<void> pumpButton(
    WidgetTester tester,
    TextEditingController controller,
    FocusNode focus,
    void Function(String) onChanged,
  ) async {
    await tester.pumpWidget(localizedApp(
      Scaffold(
        body: Center(
          child: TokenInsertButton(
            t: GlimprTokens.dark,
            controller: controller,
            focusNode: focus,
            onChanged: onChanged,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('opens the token menu and inserts the tapped token at the end',
      (tester) async {
    final controller = TextEditingController(text: 'shot_');
    addTearDown(controller.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    String? changed;
    await pumpButton(tester, controller, focus, (v) => changed = v);

    // The trigger names itself on hover.
    expect(find.byTooltip('Insert variable'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    // The menu lists token literals across categories.
    expect(find.text('%Y'), findsOneWidget);
    expect(find.text('%title'), findsOneWidget);

    // No selection set -> the token appends at the end of the field.
    await tester.tap(find.text('%Y'));
    await tester.pumpAndSettle();
    expect(controller.text, 'shot_%Y');
    expect(changed, 'shot_%Y');
  });

  testWidgets('inserts the token at the caret position', (tester) async {
    final controller = TextEditingController(text: 'abcd');
    addTearDown(controller.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    controller.selection = const TextSelection.collapsed(offset: 2);
    await pumpButton(tester, controller, focus, (_) {});

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('%Y'));
    await tester.pumpAndSettle();
    // Inserted between 'ab' and 'cd'.
    expect(controller.text, 'ab%Ycd');
  });
}
