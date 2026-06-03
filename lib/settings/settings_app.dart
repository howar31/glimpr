import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import 'login_item.dart';
import 'settings.dart';

/// The settings window content: the "Aurora" design — a frosted-glass window
/// (the blur comes from a native NSVisualEffectView behind the Flutter view) with
/// a left sidebar (General / Output / Sounds) over a content pane, in Glimpr's
/// own identity (kept in Flutter so it is identical on macOS + Windows). The
/// theme follows the system light/dark setting. The native window has an inline
/// transparent title bar, so the sidebar runs to the top edge behind the traffic
/// lights — hence the top inset. Each control persists immediately; overlay
/// engines read the values fresh on next capture.
class SettingsApp extends StatefulWidget {
  const SettingsApp({super.key, required this.settings});
  final Settings settings;

  @override
  State<SettingsApp> createState() => _SettingsAppState();
}

// Reserved at the top for the transparent title bar / traffic lights.
const _kTitleBarInset = 52.0;

const _kSections = <(String, IconData)>[
  ('General', Icons.tune),
  ('Output', Icons.image_outlined),
  ('Sounds', Icons.volume_up_outlined),
];

class _SettingsAppState extends State<SettingsApp>
    with WidgetsBindingObserver {
  int _section = 0;

  String? _saveDir;
  ImageFormat _format = ImageFormat.png;
  int _jpegQuality = 90;
  bool _saveToFile = true;
  bool _copyToClipboard = true;
  bool _shutterSound = true;
  bool _completionSound = true;
  bool _rightClickExits = true;
  bool _launchAtLogin = false;

  Settings get _s => widget.settings;

  // Cmd-W hides the settings window (the native control window handles it the
  // same way as the close button — see MainFlutterWindow's role channel).
  static const _roleChannel = MethodChannel('glimpr/role');
  void _close() => _roleChannel.invokeMethod('closeSettings');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Follow the system appearance: rebuild when it flips so the token set swaps.
  @override
  void didChangePlatformBrightness() => setState(() {});

  Future<void> _load() async {
    final dir = await _s.getSaveDirectory();
    final format = await _s.getFormat();
    final quality = await _s.getJpegQuality();
    final saveToFile = await _s.getSaveToFile();
    final clip = await _s.getCopyToClipboard();
    final shutter = await _s.getShutterSound();
    final complete = await _s.getCompletionSound();
    final rightClick = await _s.getRightClickExits();
    if (!mounted) return;
    setState(() {
      _saveDir = dir;
      _format = format;
      _jpegQuality = quality;
      _saveToFile = saveToFile;
      _copyToClipboard = clip;
      _shutterSound = shutter;
      _completionSound = complete;
      _rightClickExits = rightClick;
    });
    // Login state comes from the OS (SMAppService) over a native channel; query
    // it separately so a slow / unavailable channel never blocks the rest of the
    // settings UI (and never stalls widget tests where the channel is unmocked).
    final login = await LoginItem.isEnabled();
    if (mounted) setState(() => _launchAtLogin = login);
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
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final tokens = GlimprTokens.forBrightness(brightness);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: brightness,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: GlimprType.sans,
      ),
      home: GlimprTheme(
        tokens: tokens,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyW, meta: true): _close,
          },
          child: Focus(
            autofocus: true,
            // The base glass tint that layers over the native vibrancy blur.
            child: Material(
              type: MaterialType.transparency,
              child: ColoredBox(
                color: tokens.winBg,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sidebar(tokens),
                    Container(width: 1, color: tokens.divider),
                    Expanded(child: _content(tokens)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- sidebar -----------------------------------------------------------

  Widget _sidebar(GlimprTokens t) {
    return Container(
      width: 212,
      color: t.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Traffic-light zone (real macOS controls overlay this area).
          const SizedBox(height: _kTitleBarInset),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
            child: const Wordmark(size: 19),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                for (var i = 0; i < _kSections.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: NavItem(
                      icon: _kSections[i].$2,
                      label: _kSections[i].$1,
                      active: _section == i,
                      onTap: () => setState(() => _section = i),
                    ),
                  ),
              ],
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Glimpr 1.0.0',
              style: GlimprType.sansStyle(11.5, 500, t.fg4),
            ),
          ),
        ],
      ),
    );
  }

  // ---- content -----------------------------------------------------------

  Widget _content(GlimprTokens t) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, _kTitleBarInset, 28, 32),
      children: _pane(t),
    );
  }

  List<Widget> _pane(GlimprTokens t) {
    switch (_section) {
      case 1:
        return _outputPane(t);
      case 2:
        return _soundsPane(t);
      default:
        return _generalPane(t);
    }
  }

  // ---- panes -------------------------------------------------------------

  List<Widget> _generalPane(GlimprTokens t) {
    return [
      _h1('General', t),
      const SectionLabel('Save location', icon: Icons.folder_outlined),
      GlassCard.padded(child: _saveFolderBody(t)),
      const SizedBox(height: 15),
      const SectionLabel('Destinations', icon: Icons.layers_outlined),
      GlassCard.rows([
        SettingRow(
          title: 'Save to file',
          hint: 'Write the capture to the save folder',
          trailing: GlassToggle(
            value: _saveToFile,
            onChanged: (v) async {
              await _s.setSaveToFile(v);
              if (mounted) setState(() => _saveToFile = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: 'Copy to clipboard',
          hint: 'Put the image on the clipboard',
          trailing: GlassToggle(
            value: _copyToClipboard,
            onChanged: (v) async {
              await _s.setCopyToClipboard(v);
              if (mounted) setState(() => _copyToClipboard = v);
            },
          ),
        ),
      ]),
      const SizedBox(height: 15),
      const SectionLabel('Capture', icon: Icons.photo_camera_outlined),
      GlassCard.rows([
        SettingRow(
          title: 'Right-click exits',
          hint: 'Right-click leaves capture mode (Esc always works)',
          trailing: GlassToggle(
            value: _rightClickExits,
            onChanged: (v) async {
              await _s.setRightClickExits(v);
              if (mounted) setState(() => _rightClickExits = v);
            },
          ),
        ),
      ]),
      const SizedBox(height: 15),
      const SectionLabel('Startup', icon: Icons.power_settings_new),
      GlassCard.rows([
        SettingRow(
          title: 'Launch at login',
          hint: 'Start Glimpr automatically when you log in',
          trailing: GlassToggle(
            value: _launchAtLogin,
            onChanged: (v) async {
              final actual = await LoginItem.setEnabled(v);
              if (mounted) setState(() => _launchAtLogin = actual);
            },
          ),
        ),
      ]),
    ];
  }

  List<Widget> _outputPane(GlimprTokens t) {
    final lossy = _format == ImageFormat.jpeg;
    return [
      _h1('Output', t),
      const SectionLabel('Format', icon: Icons.image_outlined),
      GlassCard.padded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Segmented<ImageFormat>(
              full: true,
              value: _format,
              options: const [
                (ImageFormat.png, 'PNG'),
                (ImageFormat.jpeg, 'JPEG'),
              ],
              onChanged: (f) async {
                await _s.setFormat(f);
                if (mounted) setState(() => _format = f);
              },
            ),
            const SizedBox(height: 18),
            Divider(height: 1, thickness: 1, color: t.divider),
            const SizedBox(height: 18),
            Row(
              children: [
                SizedBox(
                  width: 130,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Quality',
                        style: GlimprType.sansStyle(
                          14.5,
                          600,
                          lossy ? t.fg1 : t.fg4,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lossy ? 'Compression level' : 'Lossless · n/a',
                        style: GlimprType.sansStyle(12.5, 400, t.fg3),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Opacity(
                    opacity: lossy ? 1 : 0.4,
                    child: IgnorePointer(
                      ignoring: !lossy,
                      child: GlimprSlider(
                        value: _jpegQuality.toDouble(),
                        min: 10,
                        max: 100,
                        suffix: '%',
                        onChanged: (v) =>
                            setState(() => _jpegQuality = v.round()),
                        onChangeEnd: (v) => _s.setJpegQuality(v.round()),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _soundsPane(GlimprTokens t) {
    return [
      _h1('Sounds', t),
      const SectionLabel('Sound', icon: Icons.volume_up_outlined),
      GlassCard.rows([
        SettingRow(
          icon: Icons.volume_up_outlined,
          title: 'Shutter',
          hint: 'Plays the instant a capture is taken',
          trailing: GlassToggle(
            value: _shutterSound,
            onChanged: (v) async {
              await _s.setShutterSound(v);
              if (mounted) setState(() => _shutterSound = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: 'Completion',
          hint: 'Chimes once the capture is saved / copied',
          trailing: GlassToggle(
            value: _completionSound,
            onChanged: (v) async {
              await _s.setCompletionSound(v);
              if (mounted) setState(() => _completionSound = v);
            },
          ),
        ),
      ]),
    ];
  }

  // ---- building blocks ---------------------------------------------------

  Widget _h1(String title, GlimprTokens t) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Text(
      title,
      style: GlimprType.sansStyle(25, 700, t.fg1, letterSpacing: -0.5),
    ),
  );

  Widget _saveFolderBody(GlimprTokens t) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Save folder',
                style: GlimprType.sansStyle(14.5, 600, t.fg1),
              ),
              const SizedBox(height: 3),
              Text(
                _saveDir ?? 'Default · ~/Pictures/Glimpr',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GlimprType.mono(12.5, t.fg3),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        AccentButton(
          'Choose…',
          icon: Icons.folder_open_outlined,
          onTap: _chooseDir,
        ),
        const SizedBox(width: 8),
        GhostButton('Reset', onTap: _saveDir == null ? null : _resetDir),
      ],
    );
  }
}
