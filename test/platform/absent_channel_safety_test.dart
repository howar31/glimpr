import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/record/record_bridge.dart';
import 'package:glimpr/settings/login_item.dart';

// With no MethodChannel handler registered, invokeMethod throws
// MissingPluginException — the Windows-pre-S3 case. These bridges must degrade
// to a safe default instead of throwing, so the control engine boots and the
// Settings UI renders. These lock in the already-correct degradation so a
// future edit that drops a try/catch fails CI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LoginItem.isEnabled returns false when glimpr/login is absent', () async {
    expect(await LoginItem.isEnabled(), isFalse);
  });

  test('LoginItem.setEnabled returns the real (false) state when absent', () async {
    expect(await LoginItem.setEnabled(true), isFalse);
  });

  test('RecordBridge.isAvailable returns false when glimpr/record is absent', () async {
    expect(await RecordBridge().isAvailable(), isFalse);
  });
}
