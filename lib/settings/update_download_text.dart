import '../l10n/gen/app_localizations.dart';
import '../update/updater.dart';

/// The status caption of a running update download: the bare "downloading"
/// line until the size is known, then percent + MB, plus the time estimate
/// once the transfer rate is measurable.
String updateDownloadLabel(AppLocalizations l, DownloadProgress? p) {
  final total = p?.total;
  final fraction = p?.fraction;
  if (p == null || total == null || fraction == null) {
    return l.settingsAboutUpdateDownloading;
  }
  final percent = (fraction * 100).floor();
  final received = _mb(p.received);
  final size = _mb(total);
  final remaining = p.remaining;
  if (remaining == null) {
    return l.settingsAboutUpdateDownloadProgress(percent, received, size);
  }
  return l.settingsAboutUpdateDownloadProgressEta(
      percent,
      received,
      size,
      remaining < const Duration(minutes: 1)
          ? l.settingsAboutUpdateRemainingSoon
          : l.settingsAboutUpdateRemainingMinutes(
              (remaining.inSeconds / 60).ceil()));
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
