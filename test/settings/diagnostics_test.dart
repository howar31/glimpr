import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/diagnostics.dart';

import '../support/mock_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('formatDiagnostics', () {
    test('leads with the app line, then OS, then settings and displays', () {
      final text = formatDiagnostics(
        appVersion: '1.16.0 (3)',
        isDev: true,
        platformName: 'macOS',
        locale: 'zh-TW',
        native: {
          'os': 'macOS 26.0.1 (25A362)',
          'arch': 'arm64',
          'cpu': 'Apple M2 Max',
          'displays': [
            {
              'name': 'Studio Display',
              'width': 5120,
              'height': 2880,
              'scale': 2.0,
              'primary': true,
              'edr_potential': 1.0,
              'color_space': 'Display P3',
            },
          ],
        },
        settings: {'format': 'png', 'hdr_screenshot': 'true'},
      );
      final lines = text.split('\n');
      expect(lines[0], 'Glimpr 1.16.0 (3) dev, macOS arm64');
      expect(lines[1], 'OS: macOS 26.0.1 (25A362)');
      expect(lines[2], 'CPU: Apple M2 Max');
      expect(lines[3], 'Locale: zh-TW');
      expect(lines[4], 'Settings: format=png, hdr_screenshot=true');
      // Display prefix is fixed; the remaining keys follow sorted so the two
      // native sides (std::map vs Swift dictionary) render identically.
      expect(lines[5],
          'Display 1 (primary): Studio Display, 5120x2880 @2x, color_space=Display P3, edr_potential=1.0');
      expect(lines.length, 6);
    });

    test('Windows-style scale renders as a percentage, lists GPUs', () {
      final text = formatDiagnostics(
        appVersion: '1.16.0 (0)',
        isDev: false,
        platformName: 'Windows',
        locale: 'en-US',
        native: {
          'os': 'Windows 11 (10.0.26100.4351)',
          'arch': 'x64',
          'gpus': ['NVIDIA GeForce RTX 4080', 'Intel(R) Iris(R) Xe Graphics'],
          'displays': [
            {
              'name': 'DELL AW3225QF',
              'width': 3840,
              'height': 2160,
              'scale': 1.5,
              'primary': false,
              'hdr': true,
              'sdr_white_nits': 240.0,
              'max_nits': 1000.0,
              'color_space': 12,
            },
          ],
        },
        settings: {'gpu_preference': 'system'},
      );
      final lines = text.split('\n');
      expect(lines[0], 'Glimpr 1.16.0 (0), Windows x64');
      expect(lines[1], 'OS: Windows 11 (10.0.26100.4351)');
      expect(lines[2],
          'GPU: NVIDIA GeForce RTX 4080; Intel(R) Iris(R) Xe Graphics');
      expect(lines[3], 'Locale: en-US');
      expect(lines[4], 'Settings: gpu_preference=system');
      expect(lines[5],
          'Display 1: DELL AW3225QF, 3840x2160 @150%, color_space=12, hdr=true, max_nits=1000.0, sdr_white_nits=240.0');
    });

    test('doubles print with at most three decimals', () {
      final text = formatDiagnostics(
        appVersion: '1.0.0',
        isDev: false,
        platformName: 'macOS',
        locale: 'en',
        native: {
          'displays': [
            {
              'name': 'D',
              'width': 1,
              'height': 1,
              'scale': 2.0,
              'edr_current': 1.2000000476837158,
              'edr_potential': 16.0,
              'ratio': 1.23456,
              'count': 3,
            },
          ],
        },
        settings: const {},
      );
      expect(text.split('\n').last,
          'Display 1: D, 1x1 @2x, count=3, edr_current=1.2, edr_potential=16.0, ratio=1.235');
    });

    test('a missing native map is reported instead of crashing', () {
      final text = formatDiagnostics(
        appVersion: '1.0.0',
        isDev: false,
        platformName: 'Windows',
        locale: 'en',
        native: null,
        settings: const {},
      );
      expect(text.split('\n'), [
        'Glimpr 1.0.0, Windows',
        'Native diagnostics unavailable',
        'Locale: en',
      ]);
    });
  });

  group('fetchNativeDiagnostics', () {
    test('returns the channel map with string keys', () async {
      const ch = MethodChannel('glimpr/role');
      mockMethodChannel(ch, handler: (call) {
        expect(call.method, 'diagnostics');
        return {'os': 'x', 'displays': []};
      });
      final m = await fetchNativeDiagnostics(ch);
      expect(m, {'os': 'x', 'displays': []});
    });

    test('an unimplemented channel yields null', () async {
      const ch = MethodChannel('glimpr/role-absent');
      expect(await fetchNativeDiagnostics(ch), isNull);
    });
  });
}
