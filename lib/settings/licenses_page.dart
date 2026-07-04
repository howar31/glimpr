import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../theme/glimpr_theme.dart';

// The header insets past the macOS traffic-light zone (small caption inset on
// Windows) so the back button never sits under the window controls — the ONE
// shared value settings_app uses too (they drifted when each kept a copy).
double get _kTitleBarInset => GlimprTokens.titleBarInset;

/// A package and the license entries that name it, collected from the
/// auto-generated NOTICES via [LicenseRegistry] — the SAME source Flutter's
/// stock LicensePage uses, so this list can never drift from the dependencies
/// actually bundled in the build. We only RENDER it differently.
class _LicensePackage {
  _LicensePackage(this.name);
  final String name;
  final List<LicenseEntry> entries = <LicenseEntry>[];
}

Future<List<_LicensePackage>> _collectLicenses() async {
  final map = <String, _LicensePackage>{};
  await for (final LicenseEntry entry in LicenseRegistry.licenses) {
    for (final String package in entry.packages) {
      map.putIfAbsent(package, () => _LicensePackage(package)).entries.add(entry);
    }
  }
  final list = map.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
}

/// Wrap a license route in the Glimpr theme + a solid [GlimprTokens.menuBg]
/// surface. Two purposes: every page in the flow is ONE flat colour (no window
/// vibrancy banding, no Material-elevation seams like the stock LicensePage),
/// and [GlimprTheme.of] resolves inside the pushed route (which sits outside the
/// settings window's own GlimprTheme).
Widget glimprLicenseSurface(GlimprTokens tokens, Widget child) => GlimprTheme(
      tokens: tokens,
      child: Material(color: tokens.menuBg, child: child),
    );

/// Glimpr-styled open-source license browser: a package list (master) that
/// pushes a license-text page (detail). Reuses the settings window chrome (top
/// inset for the traffic lights, flat menuBg surface).
class LicensesView extends StatefulWidget {
  const LicensesView({super.key});

  @override
  State<LicensesView> createState() => _LicensesViewState();
}

class _LicensesViewState extends State<LicensesView> {
  late final Future<List<_LicensePackage>> _future = _collectLicenses();

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    return Column(
      children: [
        _LicenseHeader(title: l.settingsAboutLicenses),
        Expanded(
          child: FutureBuilder<List<_LicensePackage>>(
            future: _future,
            builder: (context, snap) {
              if (!snap.hasData) {
                return Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: t.fg4),
                  ),
                );
              }
              final packages = snap.data!;
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 28),
                itemCount: packages.length,
                itemBuilder: (context, i) =>
                    _packageRow(context, t, l, packages[i], divider: i > 0),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _packageRow(BuildContext context, GlimprTokens t, AppLocalizations l,
      _LicensePackage p,
      {required bool divider}) {
    final row = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => glimprLicenseSurface(t, _LicenseDetailView(package: p)),
      )),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, style: GlimprType.sansStyle(14.5, 600, t.fg1)),
                  const SizedBox(height: 2),
                  Text(l.settingsLicenseCount(p.entries.length),
                      style: GlimprType.sansStyle(12.5, 400, t.fg3)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: t.fg4),
          ],
        ),
      ),
    );
    if (!divider) return row;
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.divider))),
      child: row,
    );
  }
}

/// The license text for one package: each [LicenseEntry]'s paragraphs, with
/// multiple licenses separated by a rule.
class _LicenseDetailView extends StatelessWidget {
  const _LicenseDetailView({required this.package});
  final _LicensePackage package;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final children = <Widget>[];
    for (var e = 0; e < package.entries.length; e++) {
      if (e > 0) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Divider(color: t.divider, height: 1),
        ));
      }
      for (final para in package.entries[e].paragraphs) {
        children.add(_paragraph(t, para));
      }
    }
    return Column(
      children: [
        _LicenseHeader(title: package.name),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 36),
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _paragraph(GlimprTokens t, LicenseParagraph para) {
    if (para.indent == LicenseParagraph.centeredIndent) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(para.text,
            textAlign: TextAlign.center,
            style: GlimprType.sansStyle(14, 600, t.fg1)),
      );
    }
    return Padding(
      padding: EdgeInsets.only(left: 14.0 * para.indent, bottom: 10),
      child: SelectableText(para.text,
          style: GlimprType.sansStyle(12.5, 400, t.fg2, height: 1.5)),
    );
  }
}

/// Back chevron + centered title, inset below the traffic-light zone. Shared by
/// the master + detail views; the back chevron pops the current route.
class _LicenseHeader extends StatelessWidget {
  const _LicenseHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: _kTitleBarInset),
      child: SizedBox(
        height: 48,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.chevron_left, size: 24, color: t.fg1),
                  ),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GlimprType.sansStyle(15.5, 600, t.fg1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
