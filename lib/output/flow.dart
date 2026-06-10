import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import '../capture/capture_bridge.dart';
import 'deliver.dart';
import 'filename.dart';

/// User-configurable completion actions ("what happens when a capture / the
/// editor's Done finishes"). Two flows persist in Settings — after-capture and
/// after-editor-Done — each a multi-select of these. Future actions (share
/// sheet, pin to screen, upload, OCR) are new cases here plus a [runFlow] leg.
enum FlowAction {
  copy, // image -> clipboard
  save, // image -> save folder
  openEditor, // open the result in the standalone image editor (capture only)
  copyPath, // saved file PATH -> clipboard (needs save)
  showInFinder, // reveal the saved file in Finder (needs save)
}

/// Parse a comma-joined name list (the persisted form). Unknown names are
/// dropped (forward compatible with actions added later).
Set<FlowAction> parseFlow(String? names) {
  if (names == null || names.isEmpty) return {};
  final byName = {for (final a in FlowAction.values) a.name: a};
  return {
    for (final n in names.split(','))
      if (byName[n.trim()] != null) byName[n.trim()]!,
  };
}

/// Serialize for persistence (stable declaration order).
String flowToString(Set<FlowAction> s) =>
    [for (final a in FlowAction.values) if (s.contains(a)) a.name].join(',');

/// Canonicalize a flow before running it: openEditor only exists for the
/// capture flow; copyPath yields to copy when both are checked (both write the
/// clipboard — the UI keeps them mutually exclusive, this guards stale prefs);
/// an empty flow falls back to copy so Done is never a silent discard.
Set<FlowAction> normalizeFlow(Set<FlowAction> s, {required bool forCapture}) {
  final out = {...s};
  if (!forCapture) out.remove(FlowAction.openEditor);
  if (out.contains(FlowAction.copy)) out.remove(FlowAction.copyPath);
  if (out.isEmpty) out.add(FlowAction.copy);
  return out;
}

/// [DeliveryResult] plus the extra flow legs' failures. Exposes the delivery
/// flags so existing partial-failure checks keep working unchanged.
class FlowResult {
  final DeliveryResult delivery;
  final Map<String, String> extraErrors;
  const FlowResult(this.delivery, [this.extraErrors = const {}]);

  String? get savedPath => delivery.savedPath;
  bool get savedOk => delivery.savedOk;
  bool get copiedToClipboard => delivery.copiedToClipboard;
  Map<String, String> get errors => {...delivery.errors, ...extraErrors};
}

/// Run a completion flow over an already-encoded image: the save/copy legs go
/// through [deliverCapture] (independent, partial-failure-aware), then the
/// extras in order copyPath -> showInFinder -> openEditor. copyPath and
/// showInFinder need a saved file — without one they record an error rather
/// than throwing (the Settings UI gates them on save, this guards races).
/// openEditor falls back to a temp file when nothing was saved.
Future<FlowResult> runFlow({
  required Set<FlowAction> actions,
  required Uint8List bytes,
  Directory? saveDir,
  String? fileName,
  SaveFn? saveFn,
  ClipboardFn? clipboardFn,
  SoundFn? soundFn,
  Future<void> Function(String text)? copyTextFn,
  Future<void> Function(String path)? revealFn,
  Future<void> Function(String path)? openEditorFn,
  Future<String> Function(Uint8List bytes)? writeTempFn,
}) async {
  final delivery = await deliverCapture(
    pngBytes: bytes,
    saveDir: saveDir,
    fileName: fileName,
    saveFn: saveFn,
    clipboardFn: clipboardFn,
    soundFn: soundFn,
    saveToFile: actions.contains(FlowAction.save),
    copyToClipboard: actions.contains(FlowAction.copy),
  );

  final copyText =
      copyTextFn ?? (t) => Clipboard.setData(ClipboardData(text: t));
  final reveal = revealFn ?? _revealInFinder;
  final openEditor = openEditorFn ?? CaptureBridge.openInEditor;
  final writeTemp = writeTempFn ?? ((b) => _writeTemp(b, fileName));

  final extra = <String, String>{};
  final path = delivery.savedPath;

  if (actions.contains(FlowAction.copyPath)) {
    if (path == null) {
      extra['copyPath'] = 'no saved file to copy the path of';
    } else {
      try {
        await copyText(path);
      } catch (e) {
        extra['copyPath'] = '$e';
      }
    }
  }
  if (actions.contains(FlowAction.showInFinder)) {
    if (path == null) {
      extra['showInFinder'] = 'no saved file to reveal';
    } else {
      try {
        await reveal(path);
      } catch (e) {
        extra['showInFinder'] = '$e';
      }
    }
  }
  if (actions.contains(FlowAction.openEditor)) {
    try {
      await openEditor(path ?? await writeTemp(bytes));
    } catch (e) {
      extra['openEditor'] = '$e';
    }
  }
  return FlowResult(delivery, extra);
}

Future<void> _revealInFinder(String path) async {
  await Process.run('open', ['-R', path]);
}

/// Temp file for opening an UNSAVED result in the editor. Extension follows the
/// flow's [fileName] so a JPEG flow yields a .jpg temp.
Future<String> _writeTemp(Uint8List bytes, String? fileName) async {
  final ext = fileName != null && fileName.contains('.')
      ? fileName.split('.').last
      : 'png';
  final name = screenshotFilename(DateTime.now(), ext);
  final f = File('${Directory.systemTemp.path}/$name');
  await f.writeAsBytes(bytes);
  return f.path;
}
