import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/l10n/gen/app_localizations.dart';
import 'package:glimpr/shortcuts/widgets/hotkey_recorder_field.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/theme/glimpr_theme.dart';

// The field renders KeyCapChips (which read GlimprTheme.of), so the test widget
// is wrapped in a GlimprTheme ancestor (mirrors settings_app.dart's provider).
Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GlimprTheme(
        tokens: GlimprTokens.dark,
        child: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('records Cmd+G', (tester) async {
    HotkeyBinding? out;
    await tester.pumpWidget(_wrap(
      HotkeyRecorderField(
        value: null,
        requireModifier: true,
        onChanged: (b) => out = b,
      ),
    ));
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(out, isNotNull);
    expect(out!.modifiers, contains(HotkeyModifier.meta));
    expect(out!.logicalKey, LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  });

  testWidgets('shows an Esc-to-cancel tooltip only while recording',
      (tester) async {
    await tester.pumpWidget(_wrap(
      HotkeyRecorderField(
        value: null,
        requireModifier: false,
        onChanged: (_) {},
      ),
    ));
    expect(find.byTooltip('Press Esc to cancel'), findsNothing); // idle
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    expect(find.byTooltip('Press Esc to cancel'), findsOneWidget); // recording
  });

  testWidgets('requireModifier rejects a bare key', (tester) async {
    HotkeyBinding? out;
    await tester.pumpWidget(_wrap(
      HotkeyRecorderField(
        value: null,
        requireModifier: true,
        onChanged: (b) => out = b,
      ),
    ));
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(out, isNull);
    expect(find.textContaining('modifier'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
  });

  testWidgets('reserved key rejected', (tester) async {
    HotkeyBinding? out;
    await tester.pumpWidget(_wrap(
      HotkeyRecorderField(
        value: null,
        requireModifier: false,
        reservedKeys: {LogicalKeyboardKey.escape},
        onChanged: (b) => out = b,
      ),
    ));
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    // Esc cancels recording (it is the cancel key) before reserved-check; assert
    // no binding is produced.
    expect(out, isNull);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
  });

  testWidgets('reserved arrow key shows the reserved hint', (tester) async {
    HotkeyBinding? out;
    await tester.pumpWidget(_wrap(
      HotkeyRecorderField(
        value: null,
        requireModifier: false,
        reservedKeys: {LogicalKeyboardKey.arrowUp},
        onChanged: (b) => out = b,
      ),
    ));
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(out, isNull);
    expect(find.textContaining('Reserved'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
  });

  testWidgets('Backspace is recordable (no longer a clear shortcut)',
      (tester) async {
    HotkeyBinding? out;
    await tester.pumpWidget(_wrap(
      HotkeyRecorderField(
        value: null,
        requireModifier: false, // editor tier: bare keys allowed
        onChanged: (b) => out = b,
      ),
    ));
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(out, isNotNull);
    expect(out!.logicalKey, LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
  });

  testWidgets('an external value change cancels an in-progress recording',
      (tester) async {
    // Mirrors the row's Clear/Reset buttons changing the value while the field
    // is mid-record: the field must drop back to showing the new value.
    HotkeyBinding? value = const HotkeyBinding(
      physicalKey: PhysicalKeyboardKey.keyG,
      logicalKey: LogicalKeyboardKey.keyG,
      modifiers: {HotkeyModifier.meta},
    );
    late StateSetter setOuter;
    await tester.pumpWidget(_wrap(
      StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return HotkeyRecorderField(
            value: value,
            requireModifier: true,
            onChanged: (b) => value = b,
          );
        },
      ),
    ));
    await tester.tap(find.byType(HotkeyRecorderField));
    await tester.pump();
    expect(find.text('Press keys…'), findsOneWidget); // now recording
    // External clear (like the ✕ button).
    setOuter(() => value = null);
    await tester.pump();
    expect(find.text('Press keys…'), findsNothing); // recording cancelled
  });
}
