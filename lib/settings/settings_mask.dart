import 'package:flutter/material.dart';

/// A full-area mask shown over the capture overlay AND the image editor while the
/// Settings window is open (⌘,). It dims the paused session and ABSORBS all
/// pointer input so the user can't annotate / crop / interact behind Settings —
/// avoiding conflicts (e.g. the Settings shortcut-recorder vs the editor's own
/// keys, accidental drawing, focus theft). The two surfaces use different
/// low-level pausing, but share THIS widget so they look identical.
///
/// The hint sits near the top so it stays visible above the centered Settings
/// window. Self-contained styling (a dark card, no GlimprTheme dependency) so it
/// renders correctly in the overlay, which has no theme/Scaffold ancestor.
class SettingsMask extends StatelessWidget {
  const SettingsMask({super.key});

  @override
  Widget build(BuildContext context) {
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
                    color: const Color(0xF21A2138),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0x33FFFFFF)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.tune, size: 20, color: Color(0xFFFFFFFF)),
                      SizedBox(width: 12),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Settings open',
                            style: TextStyle(
                              color: Color(0xFFFFFFFF),
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Close the Settings window to continue.',
                            style: TextStyle(
                              color: Color(0xCCFFFFFF),
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
