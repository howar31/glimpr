// Plain dart tests on purpose: TestWidgetsFlutterBinding replaces HttpClient
// with a stub that answers 400 to everything, and the production downloader
// is exercised against a real loopback server here.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/update/updater.dart';

void main() {
  late Directory stage;
  setUpAll(() async {
    stage = await Directory.systemTemp.createTemp('download-test');
  });
  tearDownAll(() => stage.delete(recursive: true));

  group('defaultDownload', () {
    late HttpServer server;
    tearDown(() => server.close(force: true));

    test('streams to disk and reports byte progress with the total',
        () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final body = List<int>.generate(50000, (i) => i & 0xff);
      server.listen((req) async {
        req.response.contentLength = body.length;
        // Two chunks so at least one intermediate progress lands.
        req.response.add(body.sublist(0, 20000));
        await req.response.flush();
        req.response.add(body.sublist(20000));
        await req.response.close();
      });
      final out = '${stage.path}${Platform.pathSeparator}dl.bin';
      final seen = <(int, int?)>[];
      await defaultDownload('http://127.0.0.1:${server.port}/a.bin', out,
          (r, t) => seen.add((r, t)));
      expect(File(out).readAsBytesSync(), body);
      expect(seen.first, (0, body.length));
      expect(seen.last, (body.length, body.length));
      expect(seen.every((e) => e.$2 == body.length), isTrue);
    });

    test('a stalled body times out instead of hanging', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final hold = Completer<void>();
      server.listen((req) async {
        req.response.contentLength = 1000;
        req.response.add(List.filled(10, 1));
        await req.response.flush();
        await hold.future; // never sends the rest
        // Closing short of contentLength throws server-side; irrelevant here.
        try {
          await req.response.close();
        } catch (_) {}
      });
      final out = '${stage.path}${Platform.pathSeparator}stall.bin';
      await expectLater(
          defaultDownload('http://127.0.0.1:${server.port}/s.bin', out,
              (_, _) {},
              stall: const Duration(milliseconds: 300)),
          throwsA(isA<TimeoutException>()));
      hold.complete();
    });

    test('a non-200 status throws', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = 404;
        await req.response.close();
      });
      final out = '${stage.path}${Platform.pathSeparator}nf.bin';
      await expectLater(
          defaultDownload('http://127.0.0.1:${server.port}/x', out, (_, _) {}),
          throwsA(isA<HttpException>()));
    });
  });
}
