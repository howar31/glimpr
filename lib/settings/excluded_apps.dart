import 'package:flutter/material.dart';

import '../capture/capture_bridge.dart';
import '../capture/excluded_app.dart';
import '../l10n/gen/app_localizations.dart';
import '../platform_gate.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import 'settings.dart';

export '../capture/excluded_app.dart';

typedef RunningAppsLoader = Future<List<ExcludedApp>> Function();
typedef AppsResolver = Future<List<ExcludedApp>> Function(List<String> ids);

/// Settings > Privacy: the applications kept out of captures. Two groups: the
/// excluded ones (each with its mode and a remove button), then the running
/// applications that own a window (each with an add button). A name filter
/// narrows both.
class PrivacyPane extends StatefulWidget {
  const PrivacyPane({
    super.key,
    required this.settings,
    this.listRunning,
    this.resolve,
  });

  final Settings settings;
  final RunningAppsLoader? listRunning;
  final AppsResolver? resolve;

  @override
  State<PrivacyPane> createState() => _PrivacyPaneState();
}

class _PrivacyPaneState extends State<PrivacyPane> {
  bool _enabled = true;

  bool _ownWindows = false;

  /// Excluded entries, in stored order.
  List<ExcludedEntry> _entries = const [];

  Iterable<String> get _ids => _entries.map((e) => e.id);

  /// Every application seen during this visit, by id: resolved stored ids,
  /// running applications, and ones switched off since the pane opened (so a
  /// mistaken tap can be undone even when the application is not running).
  final Map<String, ExcludedApp> _known = {};
  final Set<String> _others = {};

  final _filter = TextEditingController();

  RunningAppsLoader get _listRunning =>
      widget.listRunning ?? CaptureBridge().listRunningApps;
  AppsResolver get _resolve => widget.resolve ?? CaptureBridge().resolveApps;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await widget.settings.getExcludedAppsEnabled();
    final ownWindows = await widget.settings.getExcludeOwnWindows();
    final entries = await widget.settings.getExcludedApps();
    final ids = [for (final e in entries) e.id];
    final resolved = ids.isEmpty ? const <ExcludedApp>[] : await _resolve(ids);
    final running = await _listRunning();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _ownWindows = ownWindows;
      _entries = entries;
      for (final id in ids) {
        _known.putIfAbsent(id, () => ExcludedApp(id: id, name: id));
      }
      for (final a in resolved) {
        _known[a.id] = a;
      }
      for (final a in running) {
        _known[a.id] = a;
        _others.add(a.id);
      }
    });
  }

  Future<void> _refresh() async {
    final running = await _listRunning();
    if (!mounted) return;
    setState(() {
      for (final a in running) {
        _known[a.id] = a;
        _others.add(a.id);
      }
    });
  }

  Future<void> _setEnabled(bool v) async {
    await widget.settings.setExcludedAppsEnabled(v);
    if (mounted) setState(() => _enabled = v);
  }

  Future<void> _setOwnWindows(bool v) async {
    await widget.settings.setExcludeOwnWindows(v);
    await CaptureBridge().ownWindowExclusionChanged();
    if (mounted) setState(() => _ownWindows = v);
  }

  Future<void> _store(List<ExcludedEntry> next, {String? touched}) async {
    await widget.settings.setExcludedApps(next);
    if (!mounted) return;
    setState(() {
      _entries = next;
      if (touched != null) _others.add(touched);
    });
  }

  Future<void> _setExcluded(String id, bool excluded) => _store([
        for (final e in _entries)
          if (e.id != id) e,
        if (excluded) ExcludedEntry(id),
      ], touched: id);

  Future<void> _setMode(String id, ExcludeMode mode) => _store([
        for (final e in _entries) e.id == id ? ExcludedEntry(id, mode) : e,
      ]);

  /// The stored mode, mapped onto this platform's choices (a value written on
  /// the other platform reads as the default).
  ExcludeMode _modeOf(String id) {
    final mode = _entries.firstWhere((e) => e.id == id).mode;
    final valid = platformIsWindows
        ? mode == ExcludeMode.blur
        : mode == ExcludeMode.screenshots || mode == ExcludeMode.recordings;
    return valid ? mode : ExcludeMode.all;
  }

  bool _matches(ExcludedApp a) {
    final q = _filter.text.trim().toLowerCase();
    return q.isEmpty || a.name.toLowerCase().contains(q);
  }

  List<ExcludedApp> _sorted(Iterable<String> ids) {
    final apps = [
      for (final id in ids)
        if (_known[id] case final a? when _matches(a)) a,
    ];
    apps.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return apps;
  }

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    final excluded = _sorted(_ids);
    final others = _sorted(_others.where((id) => !_ids.contains(id)));
    final filtering = _filter.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard.rows([
          SettingRow(
            icon: Icons.shield_outlined,
            title: l.settingsPrivacyEnable,
            hint: platformIsWindows
                ? l.settingsPrivacyEnableHintMask
                : l.settingsPrivacyEnableHintHide,
            trailing: GlassToggle(value: _enabled, onChanged: _setEnabled),
          ),
          SettingRow(
            divider: true,
            icon: Icons.picture_in_picture_alt_outlined,
            title: l.settingsPrivacyOwnWindows,
            hint: l.settingsPrivacyOwnWindowsHint,
            trailing:
                GlassToggle(value: _ownWindows, onChanged: _setOwnWindows),
          ),
        ]),
        const SizedBox(height: 15),
        Row(
          children: [
            Expanded(child: _filterField(t, l)),
            const SizedBox(width: 4),
            IconButton(
              tooltip: l.settingsPrivacyRefresh,
              icon: Icon(Icons.refresh, size: 18, color: t.fg3),
              onPressed: _refresh,
            ),
          ],
        ),
        const SizedBox(height: 18),
        SectionLabel(
          l.settingsPrivacyExcluded,
          icon: Icons.visibility_off_outlined,
          note: '${_entries.length}',
        ),
        if (excluded.isEmpty)
          _empty(
            t,
            filtering ? l.settingsPrivacyNoMatch : l.settingsPrivacyNoneExcluded,
          )
        else
          GlassCard.rows([
            for (final (i, a) in excluded.indexed) _row(t, l, a, i, on: true),
          ]),
        const SizedBox(height: 15),
        SectionLabel(l.settingsPrivacyRunning, icon: Icons.apps),
        if (others.isEmpty)
          _empty(t, l.settingsPrivacyNoMatch)
        else
          GlassCard.rows([
            for (final (i, a) in others.indexed) _row(t, l, a, i, on: false),
          ]),
      ],
    );
  }

  Widget _row(
    GlimprTokens t,
    AppLocalizations l,
    ExcludedApp a,
    int index, {
    required bool on,
  }) {
    // Rows move between the two groups, so the control is an add / remove
    // button rather than a switch that would jump away under the pointer.
    final toggle = IconButton(
      tooltip: on ? l.settingsPrivacyRemove : l.settingsPrivacyAdd,
      icon: Icon(
        on ? Icons.remove : Icons.add,
        size: 20,
        color: on ? t.fg3 : t.accentFg,
      ),
      onPressed: () => _setExcluded(a.id, !on),
    );
    return SettingRow(
      key: ValueKey('privacy-app-${a.id}'),
      divider: index > 0,
      enabled: _enabled,
      iconWidget: _AppIcon(a, size: 22, fallback: t.fg3),
      title: a.name,
      // The identifier tells apart applications that share a name.
      hint: a.name == a.id ? null : a.id,
      trailing: !on
          ? toggle
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Segmented<ExcludeMode>(
                  value: _modeOf(a.id),
                  options: platformIsWindows
                      ? [
                          (ExcludeMode.all, l.settingsPrivacyModeBlack),
                          (ExcludeMode.blur, l.settingsPrivacyModeBlur),
                        ]
                      : [
                          (ExcludeMode.all, l.settingsPrivacyModeAll),
                          (
                            ExcludeMode.screenshots,
                            l.settingsPrivacyModeScreenshots,
                          ),
                          (
                            ExcludeMode.recordings,
                            l.settingsPrivacyModeRecordings,
                          ),
                        ],
                  onChanged: (m) => _setMode(a.id, m),
                ),
                const SizedBox(width: 6),
                toggle,
              ],
            ),
    );
  }

  Widget _empty(GlimprTokens t, String text) => GlassCard.padded(
        child: Text(text, style: GlimprType.sansStyle(12.5, 400, t.fg3)),
      );

  Widget _filterField(GlimprTokens t, AppLocalizations l) {
    return TextField(
      controller: _filter,
      style: GlimprType.sansStyle(13.5, 400, t.fg1),
      cursorColor: GlimprTokens.accent,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: t.fieldBg,
        hintText: l.settingsPrivacyFilterHint,
        hintStyle: GlimprType.sansStyle(13.5, 400, t.fg4),
        prefixIcon: Icon(Icons.search, size: 18, color: t.fg3),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 38, minHeight: 0),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: t.fieldBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: GlimprTokens.accent, width: 1.5),
        ),
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon(this.app, {required this.size, required this.fallback});
  final ExcludedApp app;
  final double size;
  final Color fallback;

  @override
  Widget build(BuildContext context) {
    final icon = app.icon;
    if (icon == null) {
      return Icon(Icons.apps, size: size, color: fallback);
    }
    return Image.memory(
      icon,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => Icon(Icons.apps, size: size, color: fallback),
    );
  }
}
