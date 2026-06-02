import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'settings.dart';

/// The settings window content: a macOS-preferences-style sidebar (categories on
/// the left) + a content pane on the right, in Glimpr's dark identity (kept in
/// Flutter so it is identical on macOS + Windows). The native window is
/// fixed-size with an inline transparent title bar, so the sidebar runs to the
/// top edge behind the traffic lights — hence the top inset. Each control
/// persists immediately; overlay engines read the values fresh on next capture.
class SettingsApp extends StatefulWidget {
  const SettingsApp({super.key, required this.settings});
  final Settings settings;

  @override
  State<SettingsApp> createState() => _SettingsAppState();
}

// Palette — shares the overlay toolbar's dark-glass identity.
const _kContentBg = Color(0xFF1A1A1C);
const _kSidebarBg = Color(0xFF222226);
const _kCard = Color(0xFF252528);
const _kCardBorder = Color(0x14FFFFFF);
const _kDivider = Color(0x12FFFFFF);
const _kAccent = Colors.lightBlueAccent; // matches the active-tool colour
const _kText = Colors.white;
const _kTextDim = Colors.white70;
const _kTextMuted = Colors.white38;

// Height reserved at the top for the transparent title bar / traffic lights.
const _kTitleBarInset = 40.0;

const _kSections = <(String, IconData)>[
  ('General', Icons.tune),
  ('Output', Icons.image_outlined),
  ('Sounds', Icons.volume_up_outlined),
];

class _SettingsAppState extends State<SettingsApp> {
  int _section = 0;

  String? _saveDir;
  ImageFormat _format = ImageFormat.png;
  int _jpegQuality = 90;
  bool _saveToFile = true;
  bool _copyToClipboard = true;
  bool _shutterSound = true;
  bool _completionSound = true;

  Settings get _s => widget.settings;

  // Cmd-W hides the settings window (the native control window handles it the
  // same way as the close button — see MainFlutterWindow's role channel).
  static const _roleChannel = MethodChannel('glimpr/role');
  void _close() => _roleChannel.invokeMethod('closeSettings');

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
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _kContentBg,
        colorScheme: const ColorScheme.dark(
          primary: _kAccent,
          surface: _kContentBg,
        ),
        switchTheme: SwitchThemeData(
          trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: _kAccent,
          thumbColor: _kAccent,
          inactiveTrackColor: const Color(0x22FFFFFF),
          overlayColor: _kAccent.withValues(alpha: 0.12),
          trackHeight: 3,
        ),
      ),
      home: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyW, meta: true): _close,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sidebar(),
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: _kCardBorder,
                ),
                Expanded(child: _content()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- sidebar -----------------------------------------------------------

  Widget _sidebar() {
    return Container(
      width: 190,
      color: _kSidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: _kTitleBarInset),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 6, 20, 16),
            child: Text(
              'Glimpr',
              style: TextStyle(
                color: _kText,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (var i = 0; i < _kSections.length; i++) _navItem(i),
        ],
      ),
    );
  }

  Widget _navItem(int i) {
    final (label, icon) = _kSections[i];
    final on = _section == i;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _section = i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: on ? _kAccent : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: on ? Colors.black87 : _kTextDim),
              const SizedBox(width: 9),
              Text(
                label,
                style: TextStyle(
                  color: on ? Colors.black87 : _kTextDim,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- content -----------------------------------------------------------

  Widget _content() {
    return Container(
      color: _kContentBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: _kTitleBarInset),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
              children: _pane(),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _pane() {
    switch (_section) {
      case 1:
        return [
          _header('Output'),
          _card([
            _tile(label: 'Format', trailing: _formatToggle()),
            if (_format == ImageFormat.jpeg) _qualityTile(),
          ]),
        ];
      case 2:
        return [
          _header('Sounds'),
          _card([
            _switchTile(
              label: 'Shutter',
              subtitle: 'Plays the instant a capture is taken',
              value: _shutterSound,
              onChanged: (v) async {
                await _s.setShutterSound(v);
                if (mounted) setState(() => _shutterSound = v);
              },
            ),
            _switchTile(
              label: 'Completion',
              subtitle: 'Chimes once the capture is saved / copied',
              value: _completionSound,
              onChanged: (v) async {
                await _s.setCompletionSound(v);
                if (mounted) setState(() => _completionSound = v);
              },
            ),
          ]),
        ];
      default:
        return [
          _header('General'),
          _card([_saveFolderTile()]),
          const SizedBox(height: 18),
          _caption('Destinations'),
          _card([
            _switchTile(
              label: 'Save to file',
              subtitle: 'Write the capture to the save folder',
              value: _saveToFile,
              onChanged: (v) async {
                await _s.setSaveToFile(v);
                if (mounted) setState(() => _saveToFile = v);
              },
            ),
            _switchTile(
              label: 'Copy to clipboard',
              subtitle: 'Put the image on the clipboard',
              value: _copyToClipboard,
              onChanged: (v) async {
                await _s.setCopyToClipboard(v);
                if (mounted) setState(() => _copyToClipboard = v);
              },
            ),
          ]),
        ];
    }
  }

  // ---- building blocks ---------------------------------------------------

  Widget _header(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Text(
      title,
      style: const TextStyle(
        color: _kText,
        fontSize: 21,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _caption(String text) => Padding(
    padding: const EdgeInsets.only(left: 6, bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: _kTextMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      ),
    ),
  );

  /// A rounded card whose rows are separated by hairline dividers.
  Widget _card(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(
          const Divider(
            height: 1,
            thickness: 1,
            color: _kDivider,
            indent: 16,
            endIndent: 16,
          ),
        );
      }
      children.add(rows[i]);
    }
    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kCardBorder),
      ),
      child: Column(children: children),
    );
  }

  /// A label (+ optional subtitle) on the left, a control on the right.
  Widget _tile({
    required String label,
    String? subtitle,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: _kText, fontSize: 13.5),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      style: const TextStyle(color: _kTextMuted, fontSize: 11.5),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }

  Widget _switchTile({
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _tile(
      label: label,
      subtitle: subtitle,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: Colors.white,
        activeTrackColor: _kAccent,
        inactiveThumbColor: Colors.white70,
        inactiveTrackColor: const Color(0x22FFFFFF),
      ),
    );
  }

  Widget _saveFolderTile() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Save folder',
            style: TextStyle(color: _kText, fontSize: 13.5),
          ),
          const SizedBox(height: 3),
          Text(
            _saveDir ?? 'Default · ~/Pictures/Glimpr',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _kTextMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _accentButton('Choose…', _chooseDir),
              const SizedBox(width: 8),
              _ghostButton('Reset', _saveDir == null ? null : _resetDir),
            ],
          ),
        ],
      ),
    );
  }

  Widget _qualityTile() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'JPEG quality',
                style: TextStyle(color: _kTextDim, fontSize: 12.5),
              ),
              const Spacer(),
              Text(
                '$_jpegQuality',
                style: const TextStyle(
                  color: _kAccent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Slider(
            value: _jpegQuality.toDouble(),
            min: 1,
            max: 100,
            divisions: 99,
            onChanged: (v) => setState(() => _jpegQuality = v.round()),
            onChangeEnd: (v) => _s.setJpegQuality(v.round()),
          ),
        ],
      ),
    );
  }

  /// Custom two-option pill (PNG / JPEG) — the selected side fills with accent.
  Widget _formatToggle() {
    Widget seg(String text, ImageFormat f) {
      final on = _format == f;
      return GestureDetector(
        onTap: () async {
          await _s.setFormat(f);
          if (mounted) setState(() => _format = f);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: on ? _kAccent : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: on ? Colors.black : _kTextDim,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg('PNG', ImageFormat.png), seg('JPEG', ImageFormat.jpeg)],
      ),
    );
  }

  Widget _accentButton(String label, VoidCallback onTap) {
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: _kAccent,
        foregroundColor: Colors.black,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }

  Widget _ghostButton(String label, VoidCallback? onTap) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: _kTextDim,
        disabledForegroundColor: _kTextMuted,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}
