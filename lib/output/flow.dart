import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, MethodChannel;
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
  shareSheet, // macOS share menu (AirDrop / Messages / ...) for the file
  pin, // float the image as an always-on-top pin window
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

/// One Settings toggle transition over a completion flow, enforcing the
/// invariants the toggles promise: copy and copyPath are mutually exclusive
/// (both write the clipboard), and copyPath / showInFinder need the save leg,
/// so unchecking save also unchecks them — otherwise they would linger checked
/// behind their disabled rows, a hidden always-failing state.
Set<FlowAction> toggleFlowAction(
    Set<FlowAction> flow, FlowAction action, bool on) {
  final next = {...flow};
  if (on) {
    next.add(action);
    if (action == FlowAction.copy) next.remove(FlowAction.copyPath);
    if (action == FlowAction.copyPath) next.remove(FlowAction.copy);
  } else {
    next.remove(action);
    if (action == FlowAction.save) {
      next.remove(FlowAction.copyPath);
      next.remove(FlowAction.showInFinder);
    }
  }
  return next;
}

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

/// The after-recording flow's applicable subset: a video never loads as
/// image bytes, so only the path-based legs make sense. save is inherent
/// (the recording IS the file); copy-image / pin / openEditor are not offered.
const kRecordingFlowActions = <FlowAction>{
  FlowAction.copyPath,
  FlowAction.showInFinder,
  FlowAction.shareSheet,
};

/// Decoration is an OUTPUT treatment: the pin leg always consumes the
/// undecorated capture (a decorated pin is oversized and breaks pin-in-place
/// alignment). A pin-only flow skips decoration entirely; when pin rides
/// along other legs the capture additionally produces a plain rendition for
/// it ([runFlow]'s pinBytes).
({bool decorate, bool needsPlainForPin}) decorationPlan({
  required bool decorationEnabled,
  required Set<FlowAction> actions,
}) {
  final decorate =
      decorationEnabled && actions.any((a) => a != FlowAction.pin);
  return (
    decorate: decorate,
    needsPlainForPin: decorate && actions.contains(FlowAction.pin),
  );
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
/// extras in order copyPath -> showInFinder -> pin -> openEditor -> shareSheet.
/// copyPath and showInFinder need a saved file — without one they record an
/// error rather than throwing (the Settings UI gates them on save, this guards
/// races). pin, openEditor and shareSheet fall back to ONE shared temp file
/// when nothing was saved.
Future<FlowResult> runFlow({
  required Set<FlowAction> actions,
  required Uint8List bytes,
  // The pin leg's plain rendition when [bytes] carries a decorated image —
  // pin always shows the undecorated capture (see [decorationPlan]). Null =
  // the pin leg shares [bytes] like every other leg.
  Uint8List? pinBytes,
  Directory? saveDir,
  String? fileName,
  SaveFn? saveFn,
  ClipboardFn? clipboardFn,
  SoundFn? soundFn,
  Future<void> Function(String text)? copyTextFn,
  Future<void> Function(String path)? revealFn,
  Future<void> Function(String path)? openEditorFn,
  Future<void> Function(String path)? shareFn,
  // Pin geometry (pin-in-place) is the CALLER's business: capture exports
  // close over their global rect here; the default pins centered.
  Future<void> Function(String path)? pinFn,
  Future<String> Function(Uint8List bytes)? writeTempFn,
  // Called with the saved path after a successful save leg — capture exports
  // record it into the shared recent-images list. Never fails the flow.
  Future<void> Function(String path)? recordRecentFn,
  // Dual-output HDR: an already-encoded HDR rendition written as a sibling
  // file beside the saved SDR image, sharing its (collision-resolved) basename
  // with [hdrExt] as the extension. Skipped when the flow has no save leg
  // (there is nowhere to sit beside); a write failure records an 'hdrFile'
  // error but never fails the flow. Only the SDR file enters recents.
  Uint8List? hdrBytes,
  String? hdrExt,
  Future<void> Function(Uint8List bytes, String path)? hdrWriteFn,
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
  if (recordRecentFn != null && delivery.savedPath != null) {
    try {
      await recordRecentFn(delivery.savedPath!);
    } catch (_) {
      // Recents are best-effort bookkeeping — never fail the flow over them.
    }
  }
  final hdrErrors = <String, String>{};
  if (hdrBytes != null && hdrExt != null && delivery.savedPath != null) {
    try {
      final hdrWrite =
          hdrWriteFn ?? ((b, p) async => File(p).writeAsBytes(b));
      await hdrWrite(hdrBytes, _siblingPath(delivery.savedPath!, hdrExt));
    } catch (e) {
      hdrErrors['hdrFile'] = '$e';
    }
  }

  final copyText =
      copyTextFn ?? (t) => Clipboard.setData(ClipboardData(text: t));
  final reveal = revealFn ?? revealInFileManager;
  final openEditor = openEditorFn ?? CaptureBridge.openInEditor;
  final share = shareFn ?? CaptureBridge.shareSheet;
  final pin = pinFn ?? ((p) => CaptureBridge.pinImage(p));
  final writeTemp = writeTempFn ?? ((b) => _writeTemp(b, fileName));

  final extra = <String, String>{};
  final path = delivery.savedPath;
  // openEditor + shareSheet both need a file; with no save leg they share ONE
  // temp write.
  String? tempPath;
  Future<String> ensureFile() async =>
      path ?? (tempPath ??= await writeTemp(bytes));

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
  if (actions.contains(FlowAction.pin)) {
    try {
      // The plain rendition gets its OWN temp (distinctly named, so it can
      // never collide with the shared share/editor temp) — the saved/temp
      // decorated file must not reach the pin.
      final pinPath = pinBytes != null
          ? await (writeTempFn ??
              ((b) => _writeTemp(b, fileName, prefix: 'pin-')))(pinBytes)
          : await ensureFile();
      await pin(pinPath);
    } catch (e) {
      extra['pin'] = '$e';
    }
  }
  if (actions.contains(FlowAction.openEditor)) {
    try {
      await openEditor(await ensureFile());
    } catch (e) {
      extra['openEditor'] = '$e';
    }
  }
  // Share is macOS-only (no system share surface on Windows v1); the toggles are
  // hidden there, but guard the action so a stale setting can't invoke it.
  if (!Platform.isWindows && actions.contains(FlowAction.shareSheet)) {
    try {
      await share(await ensureFile());
    } catch (e) {
      extra['shareSheet'] = '$e';
    }
  }
  return FlowResult(delivery, {...hdrErrors, ...extra});
}

/// The HDR sibling's path: the saved file's (collision-resolved) basename with
/// [ext] as the extension — `shot_001.png` -> `shot_001.jxr`. The SDR save's
/// `_NNN` collision handling keeps the pair's basename fresh, so the sibling
/// simply overwrites any stale file of the same name.
String _siblingPath(String savedPath, String ext) {
  final dot = savedPath.lastIndexOf('.');
  final sep = savedPath.lastIndexOf('/') > savedPath.lastIndexOf('\\')
      ? savedPath.lastIndexOf('/')
      : savedPath.lastIndexOf('\\');
  final base = dot > sep ? savedPath.substring(0, dot) : savedPath;
  return '$base.$ext';
}

/// Reveal a saved file in the OS file manager, with the file SELECTED. Shared by
/// every surface (screenshots, recording, editor) so there is ONE platform-aware
/// implementation. On Windows this routes to the native Shell API
/// (SHOpenFolderAndSelectItems) -- robust for paths with spaces and repeated
/// calls, unlike `explorer /select,<path>` which misparses a quoted space-
/// containing arg and falls back to the default folder. macOS uses `open -R`.
Future<void> revealInFileManager(String path) async {
  if (Platform.isWindows) {
    try {
      await const MethodChannel('glimpr/role')
          .invokeMethod('revealInExplorer', {'path': path});
    } catch (_) {}
  } else {
    await Process.run('open', ['-R', path]);
  }
}

/// Open a folder in the OS file manager (no selection). The folder-opening
/// sibling of [revealInFileManager], shared by every surface (tray "Open Save
/// Folder", the editor gallery's "More..." tile) so there is ONE platform-aware
/// implementation.
Future<void> openFolderInFileManager(String dirPath) async {
  await Process.run(Platform.isWindows ? 'explorer' : 'open', [dirPath]);
}

/// Temp file for opening an UNSAVED result in the editor. Extension follows the
/// flow's [fileName] so a JPEG flow yields a .jpg temp.
Future<String> _writeTemp(Uint8List bytes, String? fileName,
    {String prefix = ''}) async {
  final ext = fileName != null && fileName.contains('.')
      ? fileName.split('.').last
      : 'png';
  final name = screenshotFilename(DateTime.now(), ext);
  final f = File('${Directory.systemTemp.path}/$prefix$name');
  await f.writeAsBytes(bytes);
  return f.path;
}
