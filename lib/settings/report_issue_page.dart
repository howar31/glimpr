import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import 'licenses_page.dart' show GlimprSubpageHeader;

/// The bug-report issue form. Fields prefill from query parameters named by
/// their form ids (`diagnostics` here), so the environment snapshot lands in
/// the form without a paste.
const kIssueFormUrl =
    'https://github.com/howar31/glimpr/issues/new?template=bug_report.yml';

/// The issue-form URL with [diagnostics] prefilled. A very long snapshot is
/// left out (the Copy button covers it) so the URL stays within what every
/// browser launcher accepts.
String buildIssueUrl(String diagnostics) {
  if (diagnostics.isEmpty || diagnostics.length > 1500) return kIssueFormUrl;
  return '$kIssueFormUrl&diagnostics=${Uri.encodeQueryComponent(diagnostics)}';
}

/// "Report an issue": one sentence, the two actions ON TOP (open the GitHub
/// form, copy the snapshot), then the diagnostics block. The block can grow
/// with the display count; the buttons stay in view regardless.
class ReportIssueView extends StatefulWidget {
  const ReportIssueView({
    super.key,
    required this.report,
    required this.onOpenUrl,
    this.copyText,
  });

  /// The diagnostics text (formatDiagnostics); collected by the opener.
  final Future<String> report;
  final void Function(String url) onOpenUrl;

  /// Clipboard seam for tests; defaults to the system clipboard.
  final Future<void> Function(String text)? copyText;

  @override
  State<ReportIssueView> createState() => _ReportIssueViewState();
}

class _ReportIssueViewState extends State<ReportIssueView> {
  bool _copied = false;

  Future<void> _copy(String text) async {
    final fn = widget.copyText ??
        ((t) => Clipboard.setData(ClipboardData(text: t)));
    await fn(text);
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    return Column(
      children: [
        GlimprSubpageHeader(title: l.settingsAboutReportIssue),
        Expanded(
          child: FutureBuilder<String>(
            future: widget.report,
            builder: (context, snap) {
              final text = snap.data;
              return ListView(
                padding: const EdgeInsets.fromLTRB(28, 10, 28, 36),
                children: [
                  Text(l.reportIssueIntro,
                      style:
                          GlimprType.sansStyle(13, 400, t.fg2, height: 1.5)),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      AccentButton(l.reportIssueOpenGithub,
                          icon: Icons.north_east,
                          onTap: () =>
                              widget.onOpenUrl(buildIssueUrl(text ?? ''))),
                      GhostButton(
                          _copied ? l.reportIssueCopied : l.reportIssueCopy,
                          onTap: text == null ? null : () => _copy(text)),
                    ],
                  ),
                  const SizedBox(height: 22),
                  SectionLabel(l.reportIssueDiagnostics,
                      icon: Icons.troubleshoot),
                  GlassCard.padded(
                    pad: 14,
                    child: SelectableText(
                      text ?? l.reportIssueCollecting,
                      style: GlimprType.mono(11.5, text == null ? t.fg4 : t.fg1)
                          .copyWith(height: 1.55),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(l.reportIssuePrivacyNote,
                      style: GlimprType.sansStyle(11.5, 400, t.fg4)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
