import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'settings.dart';

/// The settings window content. This slice has one row (save folder); lay it
/// out as a list so later settings are cheap to add.
class SettingsApp extends StatefulWidget {
  const SettingsApp({super.key, required this.settings});
  final Settings settings;

  @override
  State<SettingsApp> createState() => _SettingsAppState();
}

class _SettingsAppState extends State<SettingsApp> {
  String? _saveDir;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dir = await widget.settings.getSaveDirectory();
    if (mounted) setState(() => _saveDir = dir);
  }

  Future<void> _choose() async {
    final picked = await getDirectoryPath();
    if (picked == null) return;
    await widget.settings.setSaveDirectory(picked);
    await _load();
  }

  Future<void> _reset() async {
    await widget.settings.clearSaveDirectory();
    await _load();
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
            const Text('Save folder',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(_saveDir ?? 'Default: ~/Pictures/Glimpr'),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(onPressed: _choose, child: const Text('Choose…')),
                const SizedBox(width: 8),
                TextButton(
                    onPressed: _saveDir == null ? null : _reset,
                    child: const Text('Reset to default')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
