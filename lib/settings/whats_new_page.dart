import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../theme/glimpr_theme.dart';
import '../update/release_notes.dart';
import 'licenses_page.dart' show GlimprSubpageHeader;

/// "What's new in vX.Y.Z": the release's bullet list in the settings chrome,
/// with a link to the full notes on GitHub at the end. The items come from
/// the persisted latest-release body (release_notes.dart); the page is only
/// reachable when that parse produced something.
class WhatsNewView extends StatelessWidget {
  const WhatsNewView({
    super.key,
    required this.version,
    required this.items,
    required this.releaseUrl,
    required this.onOpenUrl,
  });

  /// The release tag as shown ("v1.9.0").
  final String version;
  final List<ReleaseNoteItem> items;
  final String releaseUrl;
  final void Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    return Column(
      children: [
        GlimprSubpageHeader(title: l.settingsAboutWhatsNew(version)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 10, 28, 36),
            children: [
              for (final item in items) _item(t, item),
              const SizedBox(height: 10),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onOpenUrl(releaseUrl),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l.settingsAboutWhatsNewOnGithub,
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
