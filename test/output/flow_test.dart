import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/output/flow.dart';

void main() {
  final bytes = Uint8List.fromList([1, 2, 3]);

  group('parse / serialize', () {
    test('round-trips and drops unknown names', () {
      final s = parseFlow('copy,save,garbage,showInFinder');
      expect(s, {FlowAction.copy, FlowAction.save, FlowAction.showInFinder});
      expect(parseFlow(flowToString(s)), s);
    });

    test('null / empty parse to empty set', () {
      expect(parseFlow(null), isEmpty);
      expect(parseFlow(''), isEmpty);
    });
  });

  group('normalizeFlow', () {
    test('strips openEditor for the editor flow, keeps it for capture', () {
      final s = {FlowAction.openEditor, FlowAction.save};
      expect(normalizeFlow(s, forCapture: false), {FlowAction.save});
      expect(normalizeFlow(s, forCapture: true), s);
    });

    test('copyPath yields to copy when both present', () {
      expect(
        normalizeFlow({FlowAction.copy, FlowAction.copyPath, FlowAction.save},
            forCapture: true),
        {FlowAction.copy, FlowAction.save},
      );
    });

    test('empty set falls back to copy', () {
      expect(normalizeFlow({}, forCapture: true), {FlowAction.copy});
      expect(normalizeFlow({FlowAction.openEditor}, forCapture: false),
          {FlowAction.copy});
    });
  });

  group('decorationPlan', () {
    test('decoration off: never decorate, never plain', () {
      final p = decorationPlan(
          decorationEnabled: false,
          actions: {FlowAction.save, FlowAction.pin});
      expect(p.decorate, isFalse);
      expect(p.needsPlainForPin, isFalse);
    });

    test('pin-only flow: skip decoration entirely', () {
      final p =
          decorationPlan(decorationEnabled: true, actions: {FlowAction.pin});
      expect(p.decorate, isFalse);
      expect(p.needsPlainForPin, isFalse);
    });

    test('pin + other legs: decorate AND produce the plain rendition', () {
      final p = decorationPlan(
          decorationEnabled: true,
          actions: {FlowAction.save, FlowAction.pin});
      expect(p.decorate, isTrue);
      expect(p.needsPlainForPin, isTrue);
    });

    test('no pin: decorate, no plain rendition', () {
      final p =
          decorationPlan(decorationEnabled: true, actions: {FlowAction.copy});
      expect(p.decorate, isTrue);
      expect(p.needsPlainForPin, isFalse);
    });
  });

  group('runFlow', () {
    Future<String> save(Uint8List b, dir, String n) async => '/tmp/x/$n';
    Future<void> clip(Uint8List b) async {}

    test('copyPath + showInFinder run against the saved path', () async {
      final copied = <String>[];
      final revealed = <String>[];
      final r = await runFlow(
        actions: {
          FlowAction.save,
          FlowAction.copyPath,
          FlowAction.showInFinder,
        },
        bytes: bytes,
        fileName: 'shot.png',
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        copyTextFn: (t) async => copied.add(t),
        revealFn: (p) async => revealed.add(p),
      );
      expect(r.savedPath, '/tmp/x/shot.png');
      expect(copied, ['/tmp/x/shot.png']);
      expect(revealed, ['/tmp/x/shot.png']);
      expect(r.errors, isEmpty);
    });

    test('copyPath / showInFinder record errors when nothing was saved',
        () async {
      final r = await runFlow(
        actions: {FlowAction.copyPath, FlowAction.showInFinder},
        bytes: bytes,
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        copyTextFn: (t) async => fail('must not copy'),
        revealFn: (p) async => fail('must not reveal'),
      );
      expect(r.errors.keys, containsAll(['copyPath', 'showInFinder']));
    });

    test('openEditor uses the saved path when available, else a temp file',
        () async {
      final opened = <String>[];
      await runFlow(
        actions: {FlowAction.save, FlowAction.openEditor},
        bytes: bytes,
        fileName: 'shot.png',
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        openEditorFn: (p) async => opened.add(p),
        writeTempFn: (b) async => fail('must not write temp'),
      );
      expect(opened, ['/tmp/x/shot.png']);

      await runFlow(
        actions: {FlowAction.openEditor},
        bytes: bytes,
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        openEditorFn: (p) async => opened.add(p),
        writeTempFn: (b) async => '/tmp/temp.png',
      );
      expect(opened, ['/tmp/x/shot.png', '/tmp/temp.png']);
    });

    test('shareSheet uses the saved path; unsaved shares ONE temp with '
        'openEditor', () async {
      final shared = <String>[];
      await runFlow(
        actions: {FlowAction.save, FlowAction.shareSheet},
        bytes: bytes,
        fileName: 'shot.png',
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        shareFn: (p) async => shared.add(p),
        writeTempFn: (b) async => fail('must not write temp'),
      );
      expect(shared, ['/tmp/x/shot.png']);

      var tempWrites = 0;
      final opened = <String>[];
      await runFlow(
        actions: {FlowAction.openEditor, FlowAction.shareSheet},
        bytes: bytes,
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        openEditorFn: (p) async => opened.add(p),
        shareFn: (p) async => shared.add(p),
        writeTempFn: (b) async {
          tempWrites++;
          return '/tmp/temp.png';
        },
      );
      expect(tempWrites, 1); // one shared temp file for both legs
      expect(opened, ['/tmp/temp.png']);
      expect(shared, ['/tmp/x/shot.png', '/tmp/temp.png']);
    });

    test('pin uses the saved path, shares the temp with the other legs',
        () async {
      final pinned = <String>[];
      var tempWrites = 0;
      await runFlow(
        actions: {FlowAction.pin, FlowAction.shareSheet},
        bytes: bytes,
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        pinFn: (p) async => pinned.add(p),
        shareFn: (p) async {},
        writeTempFn: (b) async {
          tempWrites++;
          return '/tmp/temp.png';
        },
      );
      expect(pinned, ['/tmp/temp.png']);
      expect(tempWrites, 1);

      await runFlow(
        actions: {FlowAction.save, FlowAction.pin},
        bytes: bytes,
        fileName: 'shot.png',
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        pinFn: (p) async => pinned.add(p),
        writeTempFn: (b) async => fail('must not write temp'),
      );
      expect(pinned, ['/tmp/temp.png', '/tmp/x/shot.png']);
    });

    test('pin leg uses pinBytes via its own temp; other legs keep bytes',
        () async {
      final pinned = <String>[];
      final tempWrites = <Uint8List>[];
      final saved = <Uint8List>[];
      final plain = Uint8List.fromList([9, 9]);
      await runFlow(
        actions: {FlowAction.save, FlowAction.pin},
        bytes: bytes,
        pinBytes: plain,
        fileName: 'shot.png',
        saveFn: (b, d, n) async {
          saved.add(b);
          return '/tmp/x/$n';
        },
        clipboardFn: clip,
        soundFn: () async {},
        pinFn: (p) async => pinned.add(p),
        writeTempFn: (b) async {
          tempWrites.add(b);
          return '/tmp/pin-temp.png';
        },
      );
      expect(saved.single, bytes);
      expect(tempWrites.single, plain); // pin wrote ITS OWN temp from pinBytes
      expect(pinned.single, '/tmp/pin-temp.png'); // not the saved file
    });

    test('pin + shareSheet with pinBytes: the shared temp keeps the flow '
        'bytes, the pin temp the plain bytes', () async {
      final pinned = <String>[];
      final shared = <String>[];
      final tempWrites = <Uint8List>[];
      final plain = Uint8List.fromList([9, 9]);
      await runFlow(
        actions: {FlowAction.pin, FlowAction.shareSheet},
        bytes: bytes,
        pinBytes: plain,
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        pinFn: (p) async => pinned.add(p),
        shareFn: (p) async => shared.add(p),
        writeTempFn: (b) async {
          tempWrites.add(b);
          return '/tmp/temp-${tempWrites.length}.png';
        },
      );
      expect(tempWrites, [plain, bytes]); // pin leg runs before shareSheet
      expect(pinned, ['/tmp/temp-1.png']);
      expect(shared, ['/tmp/temp-2.png']);
    });

    test('save/copy legs honour the action set (delivery layer reused)',
        () async {
      var clipped = 0;
      final r = await runFlow(
        actions: {FlowAction.copy},
        bytes: bytes,
        saveFn: (b, d, n) async => fail('must not save'),
        clipboardFn: (b) async => clipped++,
        soundFn: () async {},
      );
      expect(clipped, 1);
      expect(r.savedOk, isFalse);
      expect(r.copiedToClipboard, isTrue);
    });

    test('HDR sibling is written beside the saved file (same basename)',
        () async {
      final hdrWrites = <String, int>{};
      final r = await runFlow(
        actions: {FlowAction.save},
        bytes: bytes,
        fileName: 'shot.png',
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        hdrBytes: Uint8List.fromList([1, 2, 3]),
        hdrExt: 'jxr',
        hdrWriteFn: (b, p) async => hdrWrites[p] = b.length,
      );
      expect(r.savedPath, '/tmp/x/shot.png');
      expect(hdrWrites, {'/tmp/x/shot.jxr': 3});
      expect(r.errors, isEmpty);
    });

    test('HDR sibling is skipped without a save leg and never fails the flow',
        () async {
      var clipped = 0;
      final r = await runFlow(
        actions: {FlowAction.copy},
        bytes: bytes,
        saveFn: save,
        clipboardFn: (b) async => clipped++,
        soundFn: () async {},
        hdrBytes: Uint8List.fromList([1, 2, 3]),
        hdrExt: 'jxr',
        hdrWriteFn: (b, p) async => fail('no save leg -> no HDR sibling'),
      );
      expect(clipped, 1);
      expect(r.errors, isEmpty);

      // A failing sibling write records an error but the flow still succeeds.
      final r2 = await runFlow(
        actions: {FlowAction.save},
        bytes: bytes,
        fileName: 'shot.png',
        saveFn: save,
        clipboardFn: clip,
        soundFn: () async {},
        hdrBytes: Uint8List.fromList([1, 2, 3]),
        hdrExt: 'jxr',
        hdrWriteFn: (b, p) async => throw Exception('disk full'),
      );
      expect(r2.savedPath, '/tmp/x/shot.png');
      expect(r2.errors.keys, contains('hdrFile'));
    });
  });
}
