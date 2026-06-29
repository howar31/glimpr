import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/output/sounds.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glimpr/sound');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    resetCueCacheForTest();
    // Stand-in loader so the test needs no real asset bundle: the "bytes" are
    // just the asset key, so each cue is identifiable by what it sends.
    loadCueBytes = (key) async => Uint8List.fromList(utf8.encode(key));
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    resetCueCacheForTest();
  });

  test('playShutter plays the shutter cue with its wav bytes', () async {
    MethodCall? got;
    messenger.setMockMethodCallHandler(channel, (call) async {
      got = call;
      return null;
    });
    await playShutter();
    expect(got!.method, 'play');
    final args = got!.arguments as Map;
    expect(args['id'], 'shutter');
    expect(args['bytes'],
        Uint8List.fromList(utf8.encode('assets/sounds/shutter.wav')));
  });

  test('playComplete plays the complete cue with its wav bytes', () async {
    MethodCall? got;
    messenger.setMockMethodCallHandler(channel, (call) async {
      got = call;
      return null;
    });
    await playComplete();
    expect(got!.method, 'play');
    final args = got!.arguments as Map;
    expect(args['id'], 'complete');
    expect(args['bytes'],
        Uint8List.fromList(utf8.encode('assets/sounds/complete.wav')));
  });

  test('cue bytes are loaded once and cached across repeated plays', () async {
    var loads = 0;
    loadCueBytes = (key) async {
      loads++;
      return Uint8List.fromList([7]);
    };
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    await playShutter();
    await playShutter();
    await playShutter();
    expect(loads, 1);
  });

  test('a native playback failure propagates', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => throw PlatformException(code: 'sound_play'));
    expect(playShutter, throwsA(isA<PlatformException>()));
  });
}
