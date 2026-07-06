import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Installs a mock handler on [channel] and removes it at test teardown.
/// Returns the list of calls received so tests can assert on traffic.
/// Leave [handler] null to answer every call with null (method exists,
/// reply empty); for the absent-channel case simply do not install a mock.
List<MethodCall> mockMethodChannel(
  MethodChannel channel, {
  Object? Function(MethodCall call)? handler,
}) {
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return handler?.call(call);
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return calls;
}

/// Delivers a native-to-Dart method call on [channel], as the platform side
/// would (e.g. onHotkey / onCaptureReady pushes).
Future<void> pushFromNative(
  MethodChannel channel,
  String method, [
  Object? arguments,
]) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
}
