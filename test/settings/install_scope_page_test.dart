import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/install_scope_page.dart';
import 'package:glimpr/settings/licenses_page.dart' show glimprLicenseSurface;
import 'package:glimpr/theme/glimpr_theme.dart';
import 'package:glimpr/update/updater.dart';

import '../support/localized_app.dart';

void main() {
  test('oppositeOf maps each scope to the other target', () {
    expect(oppositeOf(InstallScope.user), InstallScopeTarget.machine);
    expect(oppositeOf(InstallScope.machine), InstallScopeTarget.user);
  });

  Future<void> pump(
    WidgetTester tester, {
    required InstallScope current,
    required ValueNotifier<UpdatePhase> phase,
    required Future<InstallOutcome> Function(InstallScopeTarget) onSwitch,
  }) async {
    await tester.pumpWidget(localizedApp(glimprLicenseSurface(
      GlimprTokens.dark,
      InstallScopeView(
        current: current,
        phase: phase,
        progress: ValueNotifier<DownloadProgress?>(null),
        onSwitch: onSwitch,
      ),
    )));
    await tester.pump();
  }

  testWidgets('per-user install: explains the move to all accounts',
      (tester) async {
    await pump(tester,
        current: InstallScope.user,
        phase: ValueNotifier(UpdatePhase.idle),
        onSwitch: (_) async => InstallOutcome.handed);
    expect(find.text('Install scope'), findsOneWidget);
    expect(find.text('Glimpr is installed for this account only.'),
        findsOneWidget);
    expect(find.text('Windows asks for administrator approval once (UAC).'),
        findsOneWidget);
    expect(
        find.text(
            'Glimpr restarts; settings, recent items and launch at login are kept.'),
        findsOneWidget);
    expect(
        find.text('Glimpr becomes available to every account on this computer.'),
        findsOneWidget);
    expect(find.text('Every update asks for administrator approval.'),
        findsOneWidget);
    expect(find.text('Updates no longer ask for administrator approval.'),
        findsNothing);
    expect(find.text('Switch to all accounts'), findsOneWidget);
  });

  testWidgets('machine install: explains the move to this account only',
      (tester) async {
    await pump(tester,
        current: InstallScope.machine,
        phase: ValueNotifier(UpdatePhase.idle),
        onSwitch: (_) async => InstallOutcome.handed);
    expect(
        find.text('Glimpr is installed for all accounts on this computer.'),
        findsOneWidget);
    expect(find.text('Updates no longer ask for administrator approval.'),
        findsOneWidget);
    expect(
        find.text('Other accounts on this computer will no longer have Glimpr.'),
        findsOneWidget);
    expect(find.text('Every update asks for administrator approval.'),
        findsNothing);
    expect(find.text('Switch to this account only'), findsOneWidget);
  });

  testWidgets('the button asks for the opposite scope', (tester) async {
    final asked = <InstallScopeTarget>[];
    await pump(tester,
        current: InstallScope.machine,
        phase: ValueNotifier(UpdatePhase.idle),
        onSwitch: (t) async {
          asked.add(t);
          return InstallOutcome.handed;
        });
    await tester.tap(find.text('Switch to this account only'));
    await tester.pump();
    expect(asked, [InstallScopeTarget.user]);
  });

  testWidgets('a declined prompt returns to the button with no notice',
      (tester) async {
    await pump(tester,
        current: InstallScope.user,
        phase: ValueNotifier(UpdatePhase.idle),
        onSwitch: (_) async => InstallOutcome.cancelled);
    await tester.tap(find.text('Switch to all accounts'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Switch to all accounts'), findsOneWidget);
    expect(find.text('The switch failed; nothing was changed.'), findsNothing);
  });

  testWidgets('a failure shows the inline notice and keeps the button',
      (tester) async {
    await pump(tester,
        current: InstallScope.user,
        phase: ValueNotifier(UpdatePhase.idle),
        onSwitch: (_) async => InstallOutcome.failed);
    await tester.tap(find.text('Switch to all accounts'));
    await tester.pump();
    await tester.pump();
    expect(find.text('The switch failed; nothing was changed.'), findsOneWidget);
    expect(find.text('Switch to all accounts'), findsOneWidget);
  });

  testWidgets(
      'while downloading or installing the button gives way to the '
      'progress line', (tester) async {
    final phase = ValueNotifier(UpdatePhase.idle);
    await pump(tester,
        current: InstallScope.user,
        phase: phase,
        onSwitch: (_) async => InstallOutcome.handed);
    phase.value = UpdatePhase.downloading;
    await tester.pump();
    expect(find.text('Switch to all accounts'), findsNothing);
    expect(find.text('Downloading the update…'), findsOneWidget);
    phase.value = UpdatePhase.installing;
    await tester.pump();
    expect(find.text('Installing, the app will restart…'), findsOneWidget);
  });
}
