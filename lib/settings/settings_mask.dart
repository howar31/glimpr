import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../theme/glimpr_theme.dart';

/// A full-area mask shown over the capture overlay AND the image editor while the
/// Settings window is open (⌘,). It dims the paused session and ABSORBS all
/// pointer input so the user can't annotate / crop / interact behind Settings —
/// avoiding conflicts (e.g. the Settings shortcut-recorder vs the editor's own
/// keys, accidental drawing, focus theft). The two surfaces use different
/// low-level pausing, but share THIS widget so they look identical.
///
/// The hint sits near the top so it stays visible above the centered Settings
/// window. Tokens resolved directly from the system appearance via MediaQuery
/// (no GlimprTheme ancestor in the overlay); the card sits on the shared HUD
/// tier (GlimprTokens.hudBg/hudBorder). The dim veil stays dark in both modes
/// (matching the confirm-dialog barrier).
class SettingsMask extends StatelessWidget {
  const SettingsMask({super.key});

  @override
  Widget build(BuildContext context) {
    final t = GlimprTokens.forBrightness(
        MediaQuery.platformBrightnessOf(context));
    final fg = t.fg1;
    final fgDim = t.fg2;
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: GlimprTokens.scrim, // unified chrome dim (pure black 40%)
          child: SafeArea(
            child: Align(
              alignment: const Alignment(0, -0.72),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: t.hudBg,
                    borderRadius:
                        BorderRadius.circular(GlimprTokens.radiusCard),
                    border: Border.all(color: t.hudBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune, size: 20, color: fg),
                      const SizedBox(width: 12),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocalizations.of(context).maskSettingsOpen,
                            style: TextStyle(
                              color: fg,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            AppLocalizations.of(context).maskSettingsOpenHint,
                            style: TextStyle(
                              color: fgDim,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w400,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
