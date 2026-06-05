import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../editor/draw_style.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_core.dart';
import '../editor/tool_style_store.dart';
import '../settings/settings.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_actions.dart';
import '../shortcuts/shortcut_store.dart';
import 'image_editor_export.dart';
import 'image_editor_host.dart';

/// Standalone Image Editor window: landing state with "Open Image…" + loaded
/// state with the shared [EditorCore] at fitted size + a "Complete" bar that
/// delivers per capture settings.
class ImageEditorApp extends StatefulWidget {
  const ImageEditorApp({super.key});

  @override
  State<ImageEditorApp> createState() => _ImageEditorAppState();
}

class _ImageEditorAppState extends State<ImageEditorApp> {
  ui.Image? _image;
  Uint8List? _bytes;
  String _sourceName = 'image';
  EditorController? _controller;
  final ValueNotifier<({int id, Offset cursor})> _active = ValueNotifier(
    (id: ImageEditorHost.kImageEditorHostId, cursor: Offset.zero),
  );

  final Map<ToolKind, DrawStyle> _toolStyles = {};
  Map<String, HotkeyBinding?> _bindings = {...kDefaultBindings};
  CaptureSettings _cap = CaptureSettings.defaults;

  static const _channel = MethodChannel('glimpr/imageEditor');

  @override
  void initState() {
    super.initState();

    // Prefetch per-tool styles, hotkey bindings, and capture settings.
    // Each block is in its own try/catch so a synchronous store construction
    // error (e.g. SharedPreferences platform not set in tests) does not prevent
    // the widget from building; the defaults seeded above are used instead.
    try {
      ToolStyleStore(Settings.instance.store).load().then((styles) {
        if (mounted) setState(() => _toolStyles..addAll(styles));
      }).catchError((_) {});
    } catch (_) {}

    try {
      ShortcutStore(Settings.instance.store).all().then((b) {
        if (mounted) setState(() => _bindings = b);
      }).catchError((_) {});
    } catch (_) {}

    try {
      Settings.instance.loadCapture().then((c) {
        if (mounted) setState(() => _cap = c);
      }).catchError((_) {});
    } catch (_) {}

    // The native side sends 'loadPath' with a String path when the user chose a
    // file via the system Open panel (or via Finder "Open With").
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'loadPath') {
        final path = call.arguments as String?;
        if (path != null) await _loadPath(path);
      }
    });
  }

  /// Open the native file-picker panel; the native side returns the chosen path.
  Future<void> _openPanel() async {
    try {
      final path = await _channel.invokeMethod<String>('openPanel');
      if (path != null && mounted) await _loadPath(path);
    } catch (_) {
      // Channel unavailable (e.g. test environment) or user cancelled — ignore.
    }
  }

  /// Read, decode, and show [path] in the editor.
  Future<void> _loadPath(String path) async {
    late final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot read file: $e')),
        );
      }
      return;
    }

    ui.Image img;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      img = frame.image;
      codec.dispose();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot decode image: $e')),
        );
      }
      return;
    }

    if (!mounted) {
      img.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = img;
      _bytes = bytes;
      _sourceName = p.basenameWithoutExtension(path);
      _controller?.dispose();
      _controller = EditorController(toolStyles: _toolStyles);
    });
  }

  /// Export the annotated image and show a result snack bar.
  Future<void> _complete() async {
    final image = _image, controller = _controller;
    if (image == null || controller == null) return;
    final cap = _cap;
    final result = await exportImage(
      image: image,
      drawables: controller.document.value.drawables,
      jpeg: cap.isJpeg,
      jpegQuality: cap.jpegQuality,
      saveToFile: cap.saveToFile,
      copyToClipboard: cap.copyToClipboard,
      saveDir: cap.saveDir,
      sourceName: _sourceName,
    );
    if (!mounted) return;
    final ok = (!cap.saveToFile || result.savedOk) &&
        (!cap.copyToClipboard || result.copiedToClipboard);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Saved${result.savedPath != null ? ' to ${result.savedPath}' : ''}'
          : 'Export failed'),
    ));
  }

  @override
  void dispose() {
    _image?.dispose();
    _controller?.dispose();
    _active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final bytes = _bytes;
    final controller = _controller;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: (image == null || bytes == null || controller == null)
          ? _landing()
          : Scaffold(body: _editor(image, bytes, controller)),
    );
  }

  /// Landing state: prompt the user to open a file.
  Widget _landing() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1526),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.image),
              label: const Text('Open Image…'),
              onPressed: _openPanel,
            ),
            const SizedBox(height: 12),
            const Text(
              'or drag an image in (coming soon)',
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  /// Loaded state: fitted [EditorCore] centered above the "Complete" bar.
  Widget _editor(ui.Image image, Uint8List bytes, EditorController controller) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const barH = 56.0;
        final availW = constraints.maxWidth;
        final availH =
            (constraints.maxHeight - barH).clamp(1.0, double.infinity);
        final imgW = image.width.toDouble(), imgH = image.height.toDouble();
        final scale = (availW / imgW).clamp(0.0, availH / imgH);
        final fitted = Size(imgW * scale, imgH * scale);
        final host = ImageEditorHost(
          image: image,
          bytes: bytes,
          fittedSize: fitted,
          onComplete: _complete,
          activeSignal: _active,
        );
        return Stack(
          children: [
            Positioned.fill(
              bottom: barH,
              child: Center(
                child: SizedBox(
                  width: fitted.width,
                  height: fitted.height,
                  child: EditorCore(
                    key: ValueKey(image), // fresh State per loaded image
                    controller: controller,
                    editorBindings: _bindings,
                    host: host,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                height: barH,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                color: const Color(0xCC0F1526),
                child: FilledButton(
                  onPressed: _complete,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Complete'),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
