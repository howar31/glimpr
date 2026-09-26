import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import '../update/updater.dart';
import 'licenses_page.dart' show GlimprSubpageHeader;

/// The scope a switch from [current] moves to.
InstallScopeTarget oppositeOf(InstallScope current) =>
    current == InstallScope.user
        ? InstallScopeTarget.machine
        : InstallScopeTarget.user;

/// Settings > Advanced > Install scope (Windows): the current scope, what a
/// switch does, and the one button that performs it. The button is the
/// confirmation; there is no second dialog. While the updater downloads or
/// installs, the button gives way to the same progress line the About row
/// shows. A declined elevation prompt returns to the button silently; a
/// failed download or verification shows an inline notice.
class InstallScopeView extends StatefulWidget {
  const InstallScopeView({
    super.key,
    required this.current,
    required this.phase,
    required this.progress,
    required this.onSwitch,
  });

  final InstallScope current;
  final ValueListenable<UpdatePhase> phase;
  final ValueListenable<DownloadProgress?> progress;

  /// Performs the switch (download + verify + apply of the running version
  /// in [InstallScopeTarget]'s scope). `handed` means the app is exiting.
  final Future<InstallOutcome> Function(InstallScopeTarget target) onSwitch;

  @override
  State<InstallScopeView> createState() => _InstallScopeViewState();
}

class _InstallScopeViewState extends State<InstallScopeView> {
  bool _failed = false;
  bool _busy = false;

  Future<void> _switch() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final outcome = await widget.onSwitch(oppositeOf(widget.current));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = outcome == InstallOutcome.failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    final toMachine = widget.current == InstallScope.user;
    final effects = <String>[
      l.installScopeEffectUac,
      l.installScopeEffectRestart,
      if (toMachine)
        l.installScopeEffectMachineAll
      else
        l.installScopeEffectUserNoUac,
      if (toMachine)
        l.installScopeEffectMachineUac
      else
        l.installScopeEffectUserOthers,
    ];
    return Column(
      children: [
        GlimprSubpageHeader(title: l.settingsInstallScopeTitle),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 10, 28, 36),
            children: [
              Text(
                toMachine
                    ? l.installScopeCurrentUser
                    : l.installScopeCurrentMachine,
                style: GlimprType.sansStyle(13, 400, t.fg2, height: 1.5),
              ),
              const SizedBox(height: 22),
              SectionLabel(l.installScopeEffects, icon: Icons.info_outline),
              GlassCard.padded(
                pad: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in effects)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('•  ',
                                style: GlimprType.sansStyle(13, 400, t.fg3)),
                            Expanded(
                              child: Text(e,
                                  style: GlimprType.sansStyle(13, 400, t.fg2,
                                      height: 1.45)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              ValueListenableBuilder<UpdatePhase>(
                valueListenable: widget.phase,
                builder: (context, phase, _) {
                  switch (phase) {
                    case UpdatePhase.downloading:
                      return _progressLine(t, l);
                    case UpdatePhase.installing:
                      return Row(
                        children: [
                          SizedBox(
                            width: 11,
                            height: 11,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5, color: t.accentFg),
                          ),
                          const SizedBox(width: 6),
                          Text(l.settingsAboutUpdateInstalling,
                              style:
                                  GlimprType.sansStyle(12, 600, t.accentFg)),
                        ],
                      );
                    case UpdatePhase.idle:
                    case UpdatePhase.failed:
                      break;
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        children: [
                          AccentButton(
                            toMachine
                                ? l.installScopeSwitchToMachine
                                : l.installScopeSwitchToUser,
                            icon: Icons.swap_horiz,
                            onTap: _switch,
                          ),
                        ],
                      ),
                      if (_failed) ...[
                        const SizedBox(height: 10),
                        Text(l.installScopeFailed,
                            style: GlimprType.sansStyle(12, 500, t.fg4)),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Byte progress of the installer download (determinate when the total is
  // known), the same shape as the About row's line.
  Widget _progressLine(GlimprTokens t, AppLocalizations l) {
    return ValueListenableBuilder<DownloadProgress?>(
      valueListenable: widget.progress,
      builder: (context, p, _) {
        final fraction = p?.fraction;
        final total = p?.total;
        final label = total == null
            ? l.settingsAboutUpdateDownloading
            : l.settingsAboutUpdateDownloadProgress(
                (fraction! * 100).floor(), _mb(p!.received), _mb(total));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: GlimprType.sansStyle(12, 500, t.fg4, height: 1.15)),
            const SizedBox(height: 3),
            SizedBox(
              width: 180,
              height: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(1.5),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                  color: t.accentFg,
                  backgroundColor: t.track,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}
