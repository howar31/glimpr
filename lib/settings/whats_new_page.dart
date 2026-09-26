import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../theme/glimpr_theme.dart';
import '../update/release_notes.dart';
import '../update/version_display.dart';
import 'licenses_page.dart' show GlimprSubpageHeader;

/// "What's new": one section per release (newest first) in the settings
/// chrome, with a link to the releases page at the end. The sections come
/// from the persisted release list (release_notes.dart); the page is only
/// reachable when at least one parsed. A single section shows no version
/// heading (the page title already names it).
class WhatsNewView extends StatelessWidget {
  const WhatsNewView({
    super.key,
    required this.title,
    required this.sections,
    required this.allReleasesUrl,
    required this.onOpenUrl,
  });

  final String title;
  final List<ReleaseNoteSection> sections;
  final String allReleasesUrl;
  final void Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    final showHeadings = sections.length > 1;
    return Column(
      children: [
        GlimprSubpageHeader(title: title),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 10, 28, 36),
            children: [
              for (var s = 0; s < sections.length; s++) ...[
                if (showHeadings)
                  Padding(
                    padding: EdgeInsets.only(top: s == 0 ? 0 : 14, bottom: 10),
                    child: Text(displayVersion(sections[s].tag),
                        style: GlimprType.sansStyle(12.5, 700, t.fg3,
                            letterSpacing: 0.3)),
                  ),
                for (final item in sections[s].items) _item(t, item),
              ],
              const SizedBox(height: 10),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onOpenUrl(allReleasesUrl),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l.settingsAboutWhatsNewAllOnGithub,
                          style: GlimprType.sansStyle(12.5, 600, t.accentFg)),
                      const SizedBox(width: 3),
                      Icon(Icons.north_east, size: 13, color: t.accentFg),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _item(GlimprTokens t, ReleaseNoteItem item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 10),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                  color: t.accentFg, borderRadius: BorderRadius.circular(2.5)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(item.title,
                    style: GlimprType.sansStyle(13.5, 600, t.fg1, height: 1.35)),
                if (item.detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  SelectableText(item.detail,
                      style:
                          GlimprType.sansStyle(12.5, 400, t.fg2, height: 1.5)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
