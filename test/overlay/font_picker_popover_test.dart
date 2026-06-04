import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/style_popovers.dart';

void main() {
  testWidgets('search filters the family list (case-insensitive)', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FontPickerPopover(
          families: const ['Helvetica Neue', 'PingFang TC', 'Menlo'],
          selected: null,
          onSelected: (_) {},
        ),
      ),
    ));
    expect(find.text('Menlo'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('font-search')), 'ping');
    await t.pump();
    expect(find.text('PingFang TC'), findsOneWidget);
    expect(find.text('Menlo'), findsNothing);
  });

  testWidgets('tapping System selects null', (t) async {
    String? picked = 'unset';
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FontPickerPopover(
          families: const ['Helvetica Neue'],
          selected: 'Helvetica Neue',
          onSelected: (f) => picked = f,
        ),
      ),
    ));
    await t.tap(find.byKey(const ValueKey('font-system')));
    await t.pump();
    expect(picked, isNull);
  });
}
