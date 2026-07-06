import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glimpr/record/record_bridge.dart';
import '../support/mock_channels.dart';

const _channel = MethodChannel('glimpr/record');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start sends the full spec map with the rect expanded', () async {
    final calls = mockMethodChannel(_channel);
    await RecordBridge().start(
      mode: 'lastRegion',
      outputPath: '/tmp/rec.mp4',
      displayId: 7,
      rect: const Rect.fromLTWH(10, 20, 300, 200),
      fps: 60,
      hevc: true,
      hdr: true,
      gif: false,
      showsCursor: false,
      showScrim: false,
      systemAudio: true,
      microphone: true,
      mergeAudio: true,
      maxDuration: 90,
      countdown: 3,
      videoQuality: 'medium',
      maxLongSide: 1920,
      gifFps: 20,
    );
    expect(calls.single.method, 'start');
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    expect(args['mode'], 'lastRegion');
    expect(args['outputPath'], '/tmp/rec.mp4');
    expect(args['displayId'], 7);
    expect(args['x'], 10.0);
    expect(args['y'], 20.0);
    expect(args['w'], 300.0);
    expect(args['h'], 200.0);
    expect(args['fps'], 60);
    expect(args['hevc'], isTrue);
    expect(args['hdr'], isTrue);
    expect(args['gif'], isFalse);
    expect(args['showsCursor'], isFalse);
    expect(args['showScrim'], isFalse);
    expect(args['systemAudio'], isTrue);
    expect(args['microphone'], isTrue);
    expect(args['mergeAudio'], isTrue);
    expect(args['maxDuration'], 90);
    expect(args['countdown'], 3);
    expect(args['videoQuality'], 'medium');
    expect(args['maxLongSide'], 1920);
    expect(args['gifFps'], 20);
    // window mode not requested -> key absent.
    expect(args.containsKey('windowId'), isFalse);
  });

  test('start omits displayId and rect when not given', () async {
    final calls = mockMethodChannel(_channel);
    await RecordBridge().start(
      mode: 'window',
      outputPath: '/tmp/rec.mp4',
      windowId: 42,
    );
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    expect(args['windowId'], 42);
    expect(args.containsKey('displayId'), isFalse);
    expect(args.containsKey('x'), isFalse);
  });

  test('lifecycle controls invoke their channel methods', () async {
    final calls = mockMethodChannel(_channel);
    final bridge = RecordBridge();
    await bridge.stop();
    await bridge.abort();
    await bridge.pause();
    await bridge.resume();
    expect(calls.map((c) => c.method).toList(),
        ['stop', 'abort', 'pause', 'resume']);
  });

  test('isAvailable maps the native reply and swallows errors', () async {
    mockMethodChannel(_channel, handler: (_) => true);
    expect(await RecordBridge().isAvailable(), isTrue);

    mockMethodChannel(_channel,
        handler: (_) => throw PlatformException(code: 'nope'));
    expect(await RecordBridge().isAvailable(), isFalse);
  });

  test('registerHandlers dispatches every native lifecycle event', () async {
    final started = <(int, Rect)>[];
    final finished = <String>[];
    final failed = <String>[];
    var aborted = 0, paused = 0, resumed = 0, stopping = 0;
    final selections = <Map<String, dynamic>>[];

    RecordBridge().registerHandlers(
      onStarted: (id, rect) => started.add((id, rect)),
      onFinished: finished.add,
      onFailed: failed.add,
      onAborted: () => aborted++,
      onSelection: selections.add,
      onPaused: () => paused++,
      onResumed: () => resumed++,
      onStopping: () => stopping++,
    );
    addTearDown(() => _channel.setMethodCallHandler(null));

    await pushFromNative(_channel, 'onRecordStarted',
        {'displayId': 3, 'x': 1.0, 'y': 2.0, 'w': 100.0, 'h': 50.0});
    expect(started.single.$1, 3);
    expect(started.single.$2, const Rect.fromLTWH(1, 2, 100, 50));

    // Missing fields fall back to zeros.
    await pushFromNative(_channel, 'onRecordStarted', <String, dynamic>{});
    expect(started.last.$1, 0);
    expect(started.last.$2, Rect.zero);

    await pushFromNative(_channel, 'onRecordFinished', {'path': '/tmp/a.mp4'});
    expect(finished.single, '/tmp/a.mp4');

    await pushFromNative(_channel, 'onRecordFailed', <String, dynamic>{});
    expect(failed.single, 'unknown');

    await pushFromNative(_channel, 'onRecordAborted', null);
    await pushFromNative(_channel, 'onRecordPaused', null);
    await pushFromNative(_channel, 'onRecordResumed', null);
    await pushFromNative(_channel, 'onRecordStopping', null);
    expect((aborted, paused, resumed, stopping), (1, 1, 1, 1));

    await pushFromNative(_channel, 'onRecordSelection',
        {'displayId': 2, 'cancelled': true});
    expect(selections.single['cancelled'], isTrue);
  });
}
