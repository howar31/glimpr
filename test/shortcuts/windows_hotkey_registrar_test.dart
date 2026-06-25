import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/register_result.dart';
import 'package:glimpr/shortcuts/windows_hotkey_registrar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glimpr/hotkeys');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  HotkeyBinding ctrlAltWin1() => const HotkeyBinding(
        physicalKey: PhysicalKeyboardKey.digit1,
        logicalKey: LogicalKeyboardKey.digit1,
        modifiers: {HotkeyModifier.control, HotkeyModifier.alt, HotkeyModifier.meta},
      );

  test('register sends vk + Win32 modifier mask + keyLabel and returns ok', () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen = call;
      return true;
    });
    final reg = WindowsHotkeyRegistrar();
    final r = await reg.register('global.captureArea', ctrlAltWin1(), () {});
    expect(r, const RegisterResult.ok());
    expect(seen!.method, 'register');
    final args = seen!.arguments as Map;
    expect(args['id'], 'global.captureArea');
    expect(args['vk'], 0x31); // '1'
    expect(args['modifiers'], 0x0002 | 0x0001 | 0x0008); // Ctrl|Alt|Win
    expect(args['keyLabel'], 'Ctrl+Alt+Win+1');
  });

  test('register returns error when native says false', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    final reg = WindowsHotkeyRegistrar();
    final r = await reg.register('global.captureArea', ctrlAltWin1(), () {});
    expect(r, const RegisterResult.unavailable(UnavailableReason.error));
  });

  test('onHotkey dispatches to the registered callback, else fallback', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    final reg = WindowsHotkeyRegistrar();
    var fired = '';
    var fellBack = '';
    reg.fallback = (k) => fellBack = k;
    await reg.register('global.captureArea', ctrlAltWin1(), () => fired = 'cb');

    // Simulate the native side invoking onHotkey on the Dart handler.
    Future<void> deliver(String key) async {
      await messenger.handlePlatformMessage(
        'glimpr/hotkeys',
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('onHotkey', key)),
        (_) {},
      );
    }

    await deliver('global.captureArea');
    expect(fired, 'cb');
    await deliver('global.pinArea'); // no callback registered -> fallback
    expect(fellBack, 'global.pinArea');
  });
}
