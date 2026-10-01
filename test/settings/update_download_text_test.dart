import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/l10n/gen/app_localizations.dart';
import 'package:glimpr/settings/update_download_text.dart';
import 'package:glimpr/update/updater.dart';

void main() {
  final l = lookupAppLocalizations(const Locale('en'));
  const mb = 1024 * 1024;

  test('no progress or no total: the bare downloading line', () {
    expect(updateDownloadLabel(l, null), 'Downloading the update…');
    expect(updateDownloadLabel(l, const DownloadProgress(5, null)),
        'Downloading the update…');
  });

  test('known total without an estimate: percent and MB', () {
    expect(updateDownloadLabel(l, const DownloadProgress(3 * mb, 24 * mb)),
        'Downloading the update… 12% (3.0 / 24.0 MB)');
  });

  test('estimate: whole minutes, rounded up', () {
    expect(
        updateDownloadLabel(
            l,
            const DownloadProgress(3 * mb, 24 * mb,
                remaining: Duration(minutes: 8, seconds: 1))),
        'Downloading the update… 12% (3.0 / 24.0 MB), about 9 min left');
    expect(
        updateDownloadLabel(
            l,
            const DownloadProgress(3 * mb, 24 * mb,
                remaining: Duration(minutes: 1))),
        'Downloading the update… 12% (3.0 / 24.0 MB), about 1 min left');
  });

  test('estimate under a minute', () {
    expect(
        updateDownloadLabel(
            l,
            const DownloadProgress(23 * mb, 24 * mb,
                remaining: Duration(seconds: 59))),
        'Downloading the update… 95% (23.0 / 24.0 MB), less than 1 min left');
  });
}
