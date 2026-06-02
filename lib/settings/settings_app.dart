import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'settings.dart';

/// The settings window content: save folder, output format + JPEG quality, and
/// per-destination / per-sound toggles. Laid out as a list so new settings are
/// cheap to add. Each control persists immediately; the overlay engines read the
/// values fresh on the next capture (shared NSUserDefaults).
class SettingsApp extends StatefulWidget {
  const SettingsApp({super.key, required this.settings});
  final Settings settings;

  @override
  State<SettingsApp> createState() => _SettingsAppState();
}

class _SettingsAppState extends State<SettingsApp> {
  String? _saveDir;
  ImageFormat _format = ImageFormat.png;
  int _jpegQuality = 90;
  bool _saveToFile = true;
  bool _copyToClipboard = true;
  bool _shutterSound = true;
  bool _completionSound = true;

  Settings get _s => widget.settings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dir = await _s.getSaveDirectory();
    final format = await _s.getFormat();
    final quality = await _s.getJpegQuality();
    final saveToFile = await _s.getSaveToFile();
    final clip = await _s.getCopyToClipboard();
    final shutter = await _s.getShutterSound();
    final complete = await _s.getCompletionSound();
    if (!mounted) return;
    setState(() {
      _saveDir = dir;
      _format = format;
      _jpegQuality = quality;
      _saveToFile = saveToFile;
      _copyToClipboard = clip;
      _shutterSound = shutter;
      _completionSound = complete;
    });
  }

  Future<void> _chooseDir() async {
    final picked = await getDirectoryPath();
    if (picked == null) return;
    await _s.setSaveDirectory(picked);
    if (mounted) setState(() => _saveDir = picked);
  }

  Future<void> _resetDir() async {
    await _s.clearSaveDirectory();
    if (mounted) setState(() => _saveDir = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Glimpr Settings')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _title('Save folder'),
            const SizedBox(height: 4),
            Text(_saveDir ?? 'Default: ~/Pictures/Glimpr'),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: _chooseDir,
                  child: const Text('Choose…'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _saveDir == null ? null : _resetDir,
                  child: const Text('Reset to default'),
                ),
              ],
            ),
            const Divider(height: 32),
            _title('Output format'),
            const SizedBox(height: 8),
            SegmentedButton<ImageFormat>(
              segments: const [
                ButtonSegment(value: ImageFormat.png, label: Text('PNG')),
                ButtonSegment(value: ImageFormat.jpeg, label: Text('JPEG')),
              ],
              selected: {_format},
              onSelectionChanged: (s) async {
                final f = s.first;
                await _s.setFormat(f);
                if (mounted) setState(() => _format = f);
              },
            ),
            if (_format == ImageFormat.jpeg) ...[
              const SizedBox(height: 12),
              Text('JPEG quality: $_jpegQuality'),
              Slider(
                value: _jpegQuality.toDouble(),
                min: 1,
                max: 100,
                divisions: 99,
                label: '$_jpegQuality',
                onChanged: (v) => setState(() => _jpegQuality = v.round()),
                onChangeEnd: (v) => _s.setJpegQuality(v.round()),
              ),
            ],
            const Divider(height: 32),
            _title('Destinations'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Save to file'),
              value: _saveToFile,
              onChanged: (v) async {
                await _s.setSaveToFile(v);
                if (mounted) setState(() => _saveToFile = v);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Copy to clipboard'),
              value: _copyToClipboard,
              onChanged: (v) async {
                await _s.setCopyToClipboard(v);
                if (mounted) setState(() => _copyToClipboard = v);
              },
            ),
            const Divider(height: 32),
            _title('Sounds'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Shutter sound'),
              value: _shutterSound,
              onChanged: (v) async {
                await _s.setShutterSound(v);
                if (mounted) setState(() => _shutterSound = v);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Completion sound'),
              value: _completionSound,
              onChanged: (v) async {
                await _s.setCompletionSound(v);
                if (mounted) setState(() => _completionSound = v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _title(String text) =>
      Text(text, style: const TextStyle(fontWeight: FontWeight.bold));
}
