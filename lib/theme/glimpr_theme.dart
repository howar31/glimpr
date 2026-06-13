import 'package:flutter/widgets.dart';

/// Glimpr design-system tokens, ported verbatim from the design handoff's
/// `glimpr.css` (the "Aurora" settings theme). Two token sets — [dark] (the
/// canonical set) and [light] (its derived counterpart) — are selected by the
/// system appearance so the UI follows the OS light/dark setting.
///
/// Colors are the source's exact rgba/hex values. The window's frosted-glass
/// blur is produced natively (an NSVisualEffectView behind the Flutter view);
/// these tokens only carry the translucent tints that layer over that blur, so
/// the surfaces (window / sidebar / cards) deliberately keep their alpha.
@immutable
class GlimprTokens {
  const GlimprTokens({
    required this.brightness,
    required this.winBorder,
    required this.sidebarBg,
    required this.divider,
    required this.cardBg,
    required this.cardBgHover,
    required this.cardBorder,
    required this.insetBg,
    required this.hudBg,
    required this.hudBorder,
    required this.fg1,
    required this.fg2,
    required this.fg3,
    required this.fg4,
    required this.navActiveBg,
    required this.navActiveFg,
    required this.navHoverBg,
    required this.track,
    required this.knob,
    required this.fieldBg,
    required this.fieldBorder,
    required this.accentSoft,
    required this.accentFg,
    required this.shadowAccent,
  });

  final Brightness brightness;

  // Window / structure. No window tint: the window glass is pure native
  // vibrancy (design guide — Apple liquid glass; the Aurora navy/near-white
  // tint was removed app-wide 2026-06-13). winBorder is the bright edge that
  // defines the glass over any backdrop.
  final Color winBorder;
  final Color sidebarBg;
  final Color divider;

  // Cards / insets
  final Color cardBg;
  final Color cardBgHover;
  final Color cardBorder;
  final Color insetBg;

  // HUD tier: near-opaque chrome floating over ARBITRARY content (toasts,
  // menus, readout pills, confirm cards). ~95% opacity keeps it legible on
  // any screenshot; one pair app-wide (design guide: one glass language).
  final Color hudBg;
  final Color hudBorder;

  // Foreground ramp
  final Color fg1;
  final Color fg2;
  final Color fg3;
  final Color fg4;

  // Navigation
  final Color navActiveBg;
  final Color navActiveFg;
  final Color navHoverBg;

  // Controls
  final Color track;
  final Color knob;
  final Color fieldBg;
  final Color fieldBorder;

  // Accent surfaces
  final Color accentSoft;
  final Color accentFg;
  final Color shadowAccent;

  // --- Shared accent (theme-independent) ----------------------------------
  /// Solid accent — the locked "Blue" configuration (blue-400 → indigo-500).
  static const Color accent = Color(0xFF60A5FA); // blue-400
  static const Color accentFrom = Color(0xFF60A5FA); // blue-400
  static const Color accentTo = Color(0xFF6366F1); // indigo-500

  /// Warning / needs-attention red (e.g. a setting that needs a restart to
  /// apply). Same lightness family as the blue accent so it reads in light+dark.
  static const Color danger = Color(0xFFF87171); // red-400

  /// Recording subsystem accent (Apple dark-mode system red). The recording
  /// counterpart to [accent]: used by the menu-bar icon breath, the region
  /// frame + brackets, the recording strip, the caption record dot, and the
  /// record-select toolbar's highlights — the whole recording flow is red.
  static const Color recordingAccent = Color(0xFFFF453A);

  /// Near-solid bar background (the design guide's bar system, owner ruling
  /// 2026-06-13): bars (toolbar / option / caption / popover / native strip)
  /// are NOT liquid glass — small text + complex imagery behind would be
  /// unreadable. A near-opaque fill following dark/light keeps marks legible
  /// on ANY backdrop (white, black, busy); a faint blur may sit under it for a
  /// frosted texture (static backdrops only). Windows stay pure vibrancy.
  static const Color barBgDark = Color(0xB31A1E28); // neutral dark ~70%
  static const Color barBgLight = Color(0xB3F7F8FB); // near-white ~70%
  static const Color barBorderDark = Color(0x26FFFFFF); // ~15% white hairline
  static const Color barBorderLight = Color(0x1A0F172A); // ~10% slate hairline

  /// 135deg cyan→blue gradient used by the active controls, nav fill, wordmark.
  static const LinearGradient accentGrad = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentFrom, accentTo],
  );

  /// Text/icon color that sits on top of the accent gradient (always white).
  static const Color onAccent = Color(0xFFFFFFFF);

  /// Corner-radius ramp (design guide: one radius family app-wide).
  /// card = window-level cards/dialogs; bar = toolbars/toasts/strips;
  /// menu = popup menus + compact chrome bars; pill = mini HUD readouts;
  /// button = the ghost/accent control pair.
  static const double radiusCard = 16;
  static const double radiusBar = 12;
  static const double radiusMenu = 10;
  static const double radiusPill = 8;
  static const double radiusButton = 9;

  bool get isDark => brightness == Brightness.dark;

  // ========================== DARK (canonical) ===========================
  static const GlimprTokens dark = GlimprTokens(
    brightness: Brightness.dark,
    winBorder: Color.fromRGBO(255, 255, 255, 0.22),
    sidebarBg: Color.fromRGBO(255, 255, 255, 0.04),
    divider: Color.fromRGBO(255, 255, 255, 0.08),
    cardBg: Color.fromRGBO(255, 255, 255, 0.045),
    cardBgHover: Color.fromRGBO(255, 255, 255, 0.07),
    cardBorder: Color.fromRGBO(255, 255, 255, 0.09),
    insetBg: Color.fromRGBO(0, 0, 0, 0.22),
    hudBg: Color(0xF21A2236),
    hudBorder: Color(0x33FFFFFF),
    fg1: Color.fromRGBO(255, 255, 255, 0.96),
    fg2: Color.fromRGBO(255, 255, 255, 0.66),
    fg3: Color.fromRGBO(255, 255, 255, 0.46),
    fg4: Color.fromRGBO(255, 255, 255, 0.34),
    navActiveBg: Color.fromRGBO(96, 165, 250, 0.14),
    navActiveFg: Color(0xFF93C5FD),
    navHoverBg: Color.fromRGBO(255, 255, 255, 0.05),
    track: Color.fromRGBO(255, 255, 255, 0.12),
    knob: Color(0xFFFFFFFF),
    fieldBg: Color.fromRGBO(0, 0, 0, 0.25),
    fieldBorder: Color.fromRGBO(255, 255, 255, 0.10),
    accentSoft: Color.fromRGBO(96, 165, 250, 0.16),
    accentFg: Color(0xFF93C5FD),
    shadowAccent: Color.fromRGBO(96, 165, 250, 0.30),
  );

  // ============================== LIGHT ==================================
  static const GlimprTokens light = GlimprTokens(
    brightness: Brightness.light,
    winBorder: Color.fromRGBO(255, 255, 255, 0.70),
    sidebarBg: Color.fromRGBO(255, 255, 255, 0.14),
    divider: Color.fromRGBO(15, 23, 42, 0.08),
    cardBg: Color.fromRGBO(255, 255, 255, 0.62),
    cardBgHover: Color.fromRGBO(255, 255, 255, 0.82),
    cardBorder: Color.fromRGBO(15, 23, 42, 0.08),
    insetBg: Color.fromRGBO(15, 23, 42, 0.04),
    hudBg: Color(0xFAFFFFFF),
    hudBorder: Color(0x1F0F172A),
    fg1: Color(0xFF14223B),
    fg2: Color(0xFF475569),
    fg3: Color(0xFF64748B),
    fg4: Color(0xFF94A3B8),
    navActiveBg: Color.fromRGBO(96, 165, 250, 0.16),
    navActiveFg: Color(0xFF1D4ED8),
    navHoverBg: Color.fromRGBO(15, 23, 42, 0.05),
    track: Color.fromRGBO(15, 23, 42, 0.14),
    knob: Color(0xFFFFFFFF),
    fieldBg: Color.fromRGBO(255, 255, 255, 0.7),
    fieldBorder: Color.fromRGBO(15, 23, 42, 0.12),
    accentSoft: Color.fromRGBO(96, 165, 250, 0.18),
    accentFg: Color(0xFF1D4ED8),
    shadowAccent: Color.fromRGBO(96, 165, 250, 0.30),
  );

  static GlimprTokens forBrightness(Brightness b) =>
      b == Brightness.dark ? dark : light;
}

/// Typography for the Aurora theme. [sans] is the body face (Noto Sans TC,
/// declared in pubspec), [display] is the wordmark face (Atkinson Hyperlegible
/// Next). Both are variable fonts, so the weight is driven through a `wght`
/// [FontVariation] as well as [FontWeight] for engines that map either. [mono]
/// falls back to the platform monospace face (no bundled mono).
class GlimprType {
  static const String sans = 'Noto Sans TC';
  static const String display = 'Atkinson Hyperlegible Next';
  static const List<String> _monoFallback = ['SF Mono', 'Menlo', 'Consolas'];

  static TextStyle _styled(
    String family,
    double size,
    int weight,
    Color color, {
    double? letterSpacing,
    double? height,
  }) {
    return TextStyle(
      fontFamily: family,
      fontSize: size,
      color: color,
      fontWeight: FontWeight.values[(weight ~/ 100) - 1],
      fontVariations: [FontVariation('wght', weight.toDouble())],
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  static TextStyle sansStyle(
    double size,
    int weight,
    Color color, {
    double? letterSpacing,
    double? height,
  }) => _styled(
    sans,
    size,
    weight,
    color,
    letterSpacing: letterSpacing,
    height: height,
  );

  static TextStyle displayStyle(
    double size,
    int weight,
    Color color, {
    double? letterSpacing,
  }) => _styled(display, size, weight, color, letterSpacing: letterSpacing);

  static TextStyle mono(double size, Color color) => TextStyle(
    fontFamilyFallback: _monoFallback,
    fontSize: size,
    color: color,
    fontWeight: FontWeight.w500,
  );
}

/// Inherited holder so the design-system widgets can read the active token set
/// without threading it through every constructor.
class GlimprTheme extends InheritedWidget {
  const GlimprTheme({super.key, required this.tokens, required super.child});

  final GlimprTokens tokens;

  static GlimprTokens of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<GlimprTheme>();
    assert(t != null, 'GlimprTheme.of() called with no GlimprTheme ancestor');
    return t!.tokens;
  }

  @override
  bool updateShouldNotify(GlimprTheme oldWidget) => tokens != oldWidget.tokens;
}
