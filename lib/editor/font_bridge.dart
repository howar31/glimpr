import 'package:flutter/services.dart';

/// Enumerates system-installed font families via the native glimpr/fonts
/// channel. Fonts are NOT bundled; macOS resolves them through CoreText.
/// The list is fetched once and cached for the engine's lifetime.
class FontBridge {
  static const _channel = MethodChannel('glimpr/fonts');
  List<String>? _cache;

  Future<List<String>> availableFamilies() async {
    if (_cache != null) return _cache!;
    try {
      final list = await _channel.invokeMethod<List<dynamic>>(
        'availableFamilies',
      );
      _cache = list?.cast<String>() ?? const [];
    } catch (_) {
      _cache = const [];
    }
    return _cache!;
  }
}
