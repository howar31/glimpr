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
  });
}
