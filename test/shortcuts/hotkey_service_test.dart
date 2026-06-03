import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/shortcuts/hotkey_service.dart';
import 'package:glimpr/shortcuts/hotkey_registrar.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/register_result.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';
import 'package:flutter/services.dart';

class _FakeRegistrar implements HotkeyRegistrar {
  final registered = <String, HotkeyBinding>{};
  final unregistered = <String>[];
  bool throwOnRegister = false;
  @override
  Future<RegisterResult> register(String k, HotkeyBinding b, void Function() f) async {
    if (throwOnRegister) throw StateError('boom');
    registered[k] = b;
    return const RegisterResult.ok();
  }
  @override
  Future<void> unregister(String k) async { unregistered.add(k); registered.remove(k); }
  @override
  Future<void> unregisterAll() async { registered.clear(); }
}

void main() {
  test('start registers the captureArea default', () async {
    final reg = _FakeRegistrar();
    final svc = HotkeyService(registrar: reg, bindings: {}, onAction: (_) {});
    await svc.start();
    expect(reg.registered[kCaptureAreaKey], kDefaultBindings[kCaptureAreaKey]);
  });

  test('start skips a null (disabled) binding', () async {
    final reg = _FakeRegistrar();
    final svc = HotkeyService(
        registrar: reg, bindings: {kCaptureAreaKey: null}, onAction: (_) {});
    await svc.start();
    expect(reg.registered.containsKey(kCaptureAreaKey), isFalse);
  });

  test('rebind unregisters then registers selectively', () async {
    final reg = _FakeRegistrar();
    final svc = HotkeyService(registrar: reg, bindings: {}, onAction: (_) {});
    await svc.start();
    const next = HotkeyBinding(
      physicalKey: PhysicalKeyboardKey.keyG,
      logicalKey: LogicalKeyboardKey.keyG,
      modifiers: {HotkeyModifier.meta},
    );
    await svc.rebind(kCaptureAreaKey, next);
    expect(reg.unregistered, contains(kCaptureAreaKey));
    expect(reg.registered[kCaptureAreaKey], next);
  });

  test('rebind to null disables (unregister only)', () async {
    final reg = _FakeRegistrar();
    final svc = HotkeyService(registrar: reg, bindings: {}, onAction: (_) {});
    await svc.start();
    await svc.rebind(kCaptureAreaKey, null);
    expect(reg.registered.containsKey(kCaptureAreaKey), isFalse);
  });

  test('start swallows a registrar exception (never throws)', () async {
    final reg = _FakeRegistrar()..throwOnRegister = true;
    final svc = HotkeyService(registrar: reg, bindings: {}, onAction: (_) {});
    await svc.start(); // must not throw
  });
}
