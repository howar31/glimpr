/// Release-notes extraction for the About page's "What's new".
///
/// GitHub release bodies carry language-tagged blocks that the release page
/// does not render (HTML comments), one per language:
///
///     <!-- glimpr:notes lang=en -->
///     - **Title**: what it does for the user
///     <!-- /glimpr:notes -->
///
/// Only the bullets inside the block for the wanted language are used
/// (English when that language is missing); everything else in the body
/// (lead sentence, caveats, download table) stays on GitHub. A body without
/// any block yields null, and the About page then shows no entry.
class ReleaseNoteItem {
  const ReleaseNoteItem(this.title, this.detail);

  /// The bold lead of a bullet (or the whole bullet when it has no lead).
  final String title;

  /// The text after the lead's colon; '' when the bullet is a single phrase.
  final String detail;
}

/// One release's parsed bullets, for the What's-new page.
class ReleaseNoteSection {
  const ReleaseNoteSection(this.tag, this.items);
  final String tag;
  final List<ReleaseNoteItem> items;
}

final _blockStart = RegExp(r'<!--\s*glimpr:notes\s+lang=([A-Za-z-]+)\s*-->');
final _blockEnd = RegExp(r'<!--\s*/glimpr:notes\s*-->');
// `- **Lead**: detail` or `- **Lead**` or `- plain text`.
final _bullet = RegExp(r'^\s*[-*]\s+(.*)$');
final _boldLead = RegExp(r'^\*\*(.+?)\*\*\s*[:：]?\s*(.*)$');

/// The bullets of the block tagged [lang] (a language code such as 'zh';
/// region suffixes are ignored on both sides), falling back to 'en', or null
/// when neither block exists or the chosen block has no bullets.
List<ReleaseNoteItem>? parseReleaseNotes(String body, String lang) {
  final blocks = _blocks(body);
  if (blocks.isEmpty) return null;
  final wanted = _base(lang);
  final text = blocks[wanted] ?? blocks['en'];
  if (text == null) return null;
  final items = <ReleaseNoteItem>[];
  for (final line in text.split('\n')) {
    final b = _bullet.firstMatch(line);
    if (b == null) continue;
    final content = b.group(1)!.trim();
    if (content.isEmpty) continue;
    final lead = _boldLead.firstMatch(content);
    if (lead != null) {
      items.add(ReleaseNoteItem(lead.group(1)!.trim(), lead.group(2)!.trim()));
    } else {
      items.add(ReleaseNoteItem(_stripInline(content), ''));
    }
  }
  return items.isEmpty ? null : items;
}

Map<String, String> _blocks(String body) {
  final out = <String, String>{};
  var from = 0;
  while (true) {
    final start = _blockStart.firstMatch(body.substring(from));
    if (start == null) break;
    final contentFrom = from + start.end;
    final end = _blockEnd.firstMatch(body.substring(contentFrom));
    if (end == null) break;
    final lang = _base(start.group(1)!);
    out.putIfAbsent(
        lang, () => body.substring(contentFrom, contentFrom + end.start));
    from = contentFrom + end.end;
  }
  return out;
}

String _base(String lang) => lang.toLowerCase().split(RegExp('[-_]')).first;

// Leave plain bullets readable: drop bold/code markers, keep the words.
String _stripInline(String s) => s.replaceAll('**', '').replaceAll('`', '');
