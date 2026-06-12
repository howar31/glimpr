import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';

/// A full-area mask shown over the capture overlay AND the image editor while the
/// Settings window is open (⌘,). It dims the paused session and ABSORBS all
/// pointer input so the user can't annotate / crop / interact behind Settings —
/// avoiding conflicts (e.g. the Settings shortcut-recorder vs the editor's own
/// keys, accidental drawing, focus theft). The two surfaces use different
/// low-level pausing, but share THIS widget so they look identical.
///
/// The hint sits near the top so it stays visible above the centered Settings
/// window. Self-contained palette pair (no GlimprTheme dependency) selected by
/// the system appearance via MediaQuery, like the toolbar — so it renders
/// correctly in the overlay, which has no GlimprTheme/Scaffold ancestor. The
/// dim veil stays dark in both modes (matching the confirm-dialog barrier).
class SettingsMask extends StatelessWidget {
  const SettingsMask({super.key});

  @override
  Widget build(BuildContext context) {
    final dark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final cardBg = dark ? const Color(0xF21A2138) : const Color(0xF2EEF2F7);
    final cardBorder =
        dark ? const Color(0x33FFFFFF) : const Color(0x66FFFFFF);
    final fg = dark ? const Color(0xFFFFFFFF) : const Color(0xFF14223B);
    final fgDim = dark ? const Color(0xCCFFFFFF) : const Color(0xFF475569);
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: const Color(0x99000000), // ~60% dim
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
                    color: cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: cardBorder),
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
