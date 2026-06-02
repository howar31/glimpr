import 'package:flutter/services.dart';

/// Bridges the native macOS login-item state (SMAppService). The OS is the
/// source of truth, so this reads / writes it directly rather than persisting a
/// preference. Each call returns the ACTUAL resulting state. Failures (channel
/// missing in tests, or a register/unregister error) degrade to the real state
/// rather than throwing.
class LoginItem {
  static const _channel = MethodChannel('glimpr/login');

  static Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setEnabled(bool value) async {
    try {
      return await _channel.invokeMethod<bool>('setEnabled', value) ?? false;
    } catch (_) {
      return isEnabled(); // a failed toggle reflects the unchanged real state
    }
  }
}
