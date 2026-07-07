import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/channels.dart';
import 'package:glimpr/output/flow.dart';
import 'package:glimpr/platform_gate.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_app.dart';
import 'package:glimpr/shortcuts/widgets/key_cap_chips.dart';
import 'package:glimpr/theme/glimpr_controls.dart';

import '../support/fake_store.dart';
import '../support/mock_channels.dart';

// Pumps SettingsApp on a tall surface so lower sections of a pane are built
// (the content is a plain ListView — off-screen sections stay unbuilt at the
// default 600px height). Returns the live Settings so tests can assert writes.
Future<Settings> _pump(
  WidgetTester tester, {
  Settings? settings,
  Size view = const Size(1200, 3600),
}) async {
  tester.view.physicalSize = view;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final s = settings ?? Settings(FakeStore());
  await tester.pumpWidget(SettingsApp(settings: s));
  await tester.pumpAndSettle();
  return s;
}

// The GlassToggle inside the SettingRow whose title is [title].
Finder _toggleInRow(String title) => find.descendant(
      of: find.widgetWithText(SettingRow, title),
      matching: find.byType(GlassToggle),
    );

void main() {
  testWidgets('shows the default hint when no folder is set', (tester) async {
    final settings = Settings(FakeStore());
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    // The save folder moved to the Output pane.
    await tester.tap(find.text('Output'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Default'), findsOneWidget);
  });

  testWidgets('shows the stored folder when one is set', (tester) async {
    final settings = Settings(FakeStore());
    await settings.setSaveDirectory('/tmp/shots');
    // A fresh mount models opening the settings window with the stored value.
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Output'));
    await tester.pumpAndSettle();
    // The wider save-folder line splits the path into an ellipsizing head and a
    // pinned trailing segment, so the full string is no longer one Text widget.
    // 'shots' now also appears in the combined output-path preview, so match
    // widgets (>=1); the save-folder line is asserted precisely via its Tooltip.
    expect(find.textContaining('shots'), findsWidgets);
    expect(find.byTooltip('/tmp/shots'), findsOneWidget);
  });

  testWidgets('General pane has the language picker', (tester) async {
    final settings = Settings(FakeStore());
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    // General is the default pane.
    expect(find.text('Language'), findsOneWidget);
    await tester.tap(find.text('繁體中文'));
    await tester.pumpAndSettle();
    expect(await settings.getAppLanguage(), 'zh');
    // Changing from the launch value shows the restart hint.
    expect(find.text('Restart Glimpr for this to take effect.'),
        findsOneWidget);
  });

  testWidgets('Advanced pane has the capture layers setting', (tester) async {
    // Tall surface so the whole Advanced pane builds (the layers card sits
    // below the multi-display card, off-screen at the default test size).
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = Settings(FakeStore());
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Screenshot layers'), findsOneWidget);
    // Picking 3 persists (the warm-engines Segmented also renders a '3', so
    // target the LAST one: the layers row sits below the engines row).
    await tester.tap(find.text('3').last);
    await tester.pumpAndSettle();
    expect(await settings.getCaptureLayerCap(), 3);
  });

  // ---- Screenshot pane ---------------------------------------------------

  testWidgets('Screenshot pane: switching to JPEG persists and drives quality',
      (tester) async {
    final s = await _pump(tester);
    await tester.tap(find.text('Screenshot'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JPEG'));
    await tester.pumpAndSettle();
    expect(await s.getFormat(), ImageFormat.jpeg);
    // Drag the (now-revealed) quality slider left to lower the value. A small
    // first move engages the horizontal-drag recognizer; the pumps let the
    // slider rebuild with the new value so onChangeEnd persists it (it re-reads
    // widget.value, stale within a single un-pumped gesture — save would else
    // re-commit 90).
    final g = await tester.startGesture(
        tester.getCenter(find.byType(GlimprSlider)));
    await g.moveBy(const Offset(-20, 0));
    await tester.pump();
    await g.moveBy(const Offset(-130, 0));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    final q = await s.getJpegQuality();
    expect(q, lessThan(90));
    expect(q, inInclusiveRange(10, 100));
  });

  testWidgets('Screenshot pane: a behaviour toggle persists', (tester) async {
    final s = await _pump(tester);
    await tester.tap(find.text('Screenshot'));
    await tester.pumpAndSettle();
    // "Confirm before discarding" defaults on; turning it off persists false.
    await tester.tap(_toggleInRow('Confirm before discarding'));
    await tester.pumpAndSettle();
    expect(await s.getConfirmOnExit(), isFalse);
  });

  testWidgets(
      'Screenshot pane: enabling copy-path drops copy, and turning save off '
      'cascades the path legs off + disables their rows', (tester) async {
    final s = await _pump(tester);
    await tester.tap(find.text('Screenshot'));
    await tester.pumpAndSettle();

    // Default after-screenshot flow is {copy, save}. Enabling "Copy file path"
    // is mutually exclusive with "Copy to clipboard" (both write the clipboard).
    await tester.tap(_toggleInRow('Copy file path'));
    await tester.pumpAndSettle();
    var flow = await s.getAfterCaptureFlow();
    expect(flow, contains(FlowAction.copyPath));
    expect(flow, isNot(contains(FlowAction.copy)));
    expect(flow, contains(FlowAction.save));

    // Turning "Save to file" off cascades copyPath (and showInFinder) off — they
    // need a saved file, so they can't linger checked behind a disabled row.
    await tester.tap(_toggleInRow('Save to file'));
    await tester.pumpAndSettle();
    flow = await s.getAfterCaptureFlow();
    expect(flow, isNot(contains(FlowAction.save)));
    expect(flow, isNot(contains(FlowAction.copyPath)));

    // The copy-path row is now visually disabled (Opacity + IgnorePointer).
    expect(
      find.descendant(
        of: find.widgetWithText(SettingRow, 'Copy file path'),
        matching: find.byType(IgnorePointer),
      ),
      findsOneWidget,
    );
  });

  // ---- Recording pane ----------------------------------------------------

  testWidgets('Recording pane: shows the unavailable hint without the module',
      (tester) async {
    // RecordBridge().isAvailable() swallows the absent native channel -> false,
    // so the pane shows only the unavailable notice (no Format section).
    final s = await _pump(tester);
    await tester.tap(find.text('Recording'));
    await tester.pumpAndSettle();
    expect(find.text('H.264'), findsNothing);
    expect(s, isNotNull);
  });

  testWidgets('Recording pane: shows the format controls when available',
      (tester) async {
    mockMethodChannel(
      const MethodChannel('glimpr/record'),
      handler: (call) => call.method == 'isAvailable' ? true : null,
    );
    await _pump(tester);
    await tester.tap(find.text('Recording'));
    await tester.pumpAndSettle();
    // The Format section's codec Segmented offers H.264 / HEVC / GIF.
    expect(find.text('H.264'), findsOneWidget);
    expect(find.text('GIF'), findsOneWidget);
  });

  // ---- Output pane -------------------------------------------------------

  testWidgets('Output pane: staged filename + subfolder persist on Apply',
      (tester) async {
    final s = await _pump(tester);
    await tester.tap(find.text('Output'));
    await tester.pumpAndSettle();
    // Two pattern TextFields in field order: [subfolder, filename].
    final subfolderField = find.byType(TextField).at(0);
    final filenameField = find.byType(TextField).at(1);

    // Editing a field stages the draft (no write yet) and reveals Apply/Revert.
    await tester.enterText(subfolderField, 'shots/%Y');
    await tester.enterText(filenameField, 'myshot_%i');
    await tester.pump();
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Revert'), findsOneWidget);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(await s.getFilenameTemplate(), 'myshot_%i');
    expect(await s.getSubfolderPattern(), 'shots/%Y');
    // Applied => clean => the footer bar is gone.
    expect(find.text('Apply'), findsNothing);
  });

  testWidgets('Output pane: Revert discards the staged edit', (tester) async {
    final s = await _pump(tester);
    await tester.tap(find.text('Output'));
    await tester.pumpAndSettle();
    final filenameField = find.byType(TextField).at(1);

    await tester.enterText(filenameField, 'draft_only');
    await tester.pump();
    expect(find.text('Revert'), findsOneWidget);
    await tester.tap(find.text('Revert'));
    await tester.pumpAndSettle();
    // Revert restores the baseline draft; nothing was persisted.
    expect(await s.getFilenameTemplate(), isNot('draft_only'));
    expect(find.text('Apply'), findsNothing);
  });

  // ---- About pane --------------------------------------------------------

  testWidgets('About pane: renders the links + version and opens a URL',
      (tester) async {
    final calls = mockMethodChannel(
      kRoleChannel,
      handler: (call) => call.method == 'appVersion' ? '2.1.0 (42)' : null,
    );
    await _pump(tester);
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    expect(find.text('Support'), findsOneWidget);
    expect(find.text('Source code'), findsOneWidget);
    expect(find.text('Website'), findsOneWidget);
    expect(find.text('Licenses & acknowledgements'), findsOneWidget);
    // The About pane shows the full version; the sidebar shows just x.y.z.
    expect(find.text('2.1.0 (42)'), findsOneWidget);
    expect(find.text('Glimpr 2.1.0'), findsOneWidget);

    await tester.tap(find.text('Source code'));
    await tester.pump();
    expect(calls.any((c) => c.method == 'openExternalUrl'), isTrue);
  });

  // ---- Advanced pane, platform-shaped ------------------------------------

  testWidgets('Advanced pane on macOS shows the mac-only sections',
      (tester) async {
    debugPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugPlatformOverride = null);
    await _pump(tester);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Warm screenshot engines'), findsOneWidget);
    expect(find.text('Precise element snap (experimental)'), findsOneWidget);
    expect(find.text('Screenshot layers'), findsOneWidget);
  });

  testWidgets('Advanced pane on Windows hides the mac-only sections',
      (tester) async {
    debugPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugPlatformOverride = null);
    await _pump(tester);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    // The warm-engine pool + AX element-snap toggle are macOS-only.
    expect(find.text('Warm screenshot engines'), findsNothing);
    expect(find.text('Precise element snap (experimental)'), findsNothing);
    // The capture-layer cap is cross-platform.
    expect(find.text('Screenshot layers'), findsOneWidget);
  });

  testWidgets('Advanced pane: element-snap toggle persists (macOS)',
      (tester) async {
    debugPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugPlatformOverride = null);
    // Report AX already trusted so toggling on does NOT kick off the 1s polling
    // recheck loop (which would leave a pending timer).
    mockMethodChannel(
      const MethodChannel('glimpr/capture'),
      handler: (call) =>
          call.method == 'accessibilityTrusted' ? true : null,
    );
    final s = await _pump(tester);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    // The element-snap card holds the only GlassToggle on the Advanced pane.
    expect(find.byType(GlassToggle), findsOneWidget);
    await tester.tap(find.byType(GlassToggle));
    await tester.pump();
    // Toggling on kicks off the 1s AX-permission recheck poll; the mocked
    // "trusted" reply lets it exit after one tick — drain it so no timer leaks.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(await s.getSnapElementMode(), isTrue);
  });

  // ---- Shortcuts pane, reserved rows (platform-shaped) -------------------

  testWidgets('Shortcuts Reserved rows use Ctrl + hide element-snap on Windows',
      (tester) async {
    debugPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugPlatformOverride = null);
    await _pump(tester, view: const Size(1100, 6000));
    await tester.tap(find.text('Shortcuts'));
    await tester.pumpAndSettle();
    // The fixed close-window chord is Ctrl-based on Windows (⌘ on macOS).
    expect(
      find.descendant(
        of: find.widgetWithText(SettingRow, 'Close window'),
        matching: find.widgetWithText(KeyCap, 'Ctrl'),
      ),
      findsOneWidget,
    );
    // The element-snap walk keys are a macOS-only reserved row.
    expect(find.text('Element snap level'), findsNothing);
  });

  testWidgets('Shortcuts Reserved shows the element-snap row on macOS',
      (tester) async {
    debugPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugPlatformOverride = null);
    await _pump(tester, view: const Size(1100, 6000));
    await tester.tap(find.text('Shortcuts'));
    await tester.pumpAndSettle();
    expect(find.text('Element snap level'), findsOneWidget);
    // The reserved close-window chord uses the ⌘ cap on macOS.
    expect(
      find.descendant(
        of: find.widgetWithText(SettingRow, 'Close window'),
        matching: find.widgetWithText(KeyCap, '⌘'),
      ),
      findsOneWidget,
    );
  });
}
