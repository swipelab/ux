import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ux/video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a network player is created before its header downloads', (
    tester,
  ) async {
    final video = await rootBundle.load('integration_test/assets/portrait.mp4');
    final server = await _HeldVideoServer.start(video.buffer.asUint8List());
    addTearDown(server.close);
    final backend = MethodChannelXVideoPlayerBackend();

    final created = await backend.create(uri: server.uri.toString());
    addTearDown(() => backend.disposeInstance(created.handle));
    expect(await server.served(), isFalse);

    server.release();
    final metadata = await backend.initialize(created.handle);
    expect(metadata.size, const Size(16, 32));
    expect(metadata.duration, const Duration(seconds: 1));
    expect(metadata.rotationQuarterTurns, Platform.isAndroid ? 0 : 1);
  });

  testWidgets('a rotated video renders upright through XVideoPlayerView', (
    tester,
  ) async {
    final controller = XVideoPlayerController.file(
      await _assetFile('portrait.mp4'),
    );
    addTearDown(controller.dispose);
    await tester.runAsync(() async {
      await controller.initialize();
      await controller.play();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    final boundary = GlobalKey();
    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          key: boundary,
          child: SizedBox(
            width: 160,
            height: 320,
            child: XVideoPlayerView(controller: controller),
          ),
        ),
      ),
    );
    final pixels = (await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      return image.toByteData(format: ui.ImageByteFormat.rawRgba);
    }))!;
    int luma(int x, int y) => pixels.getUint8((y * 160 + x) * 4 + 1);

    // portrait.mp4 shows white over black once its -90° display matrix applies.
    expect(
      [luma(40, 80), luma(120, 80), luma(40, 240), luma(120, 240)],
      [greaterThan(200), greaterThan(200), lessThan(55), lessThan(55)],
    );
  });

  testWidgets('disposing a player answers its pending initialize', (
    tester,
  ) async {
    final video = await rootBundle.load('integration_test/assets/portrait.mp4');
    final server = await _HeldVideoServer.start(video.buffer.asUint8List());
    addTearDown(server.close);
    final backend = MethodChannelXVideoPlayerBackend();

    final created = await backend.create(uri: server.uri.toString());
    final initialized = expectLater(
      backend.initialize(created.handle).timeout(const Duration(seconds: 5)),
      throwsA(
        isA<XVideoPlayerException>().having((e) => e.code, 'code', 'disposed'),
      ),
    );
    await backend.disposeInstance(created.handle);
    await initialized;
  });

  testWidgets(
    'a video that fails to load before initialize emits playback_failed, '
    'then initialize fails with decode_failed',
    (tester) async {
      final file = await _tempFile('broken.mp4', utf8.encode('not a video'));
      final backend = MethodChannelXVideoPlayerBackend();
      // Opens the event channel before create; no player has handle 0.
      final channel = backend.events(0).listen(null);
      addTearDown(channel.cancel);

      final created = await backend.create(uri: 'file://${file.path}');
      addTearDown(() => backend.disposeInstance(created.handle));
      final event = await backend
          .events(created.handle)
          .first
          .timeout(const Duration(seconds: 5));
      expect(
        event,
        isA<XVideoPlayerError>().having(
          (e) => e.code,
          'code',
          'playback_failed',
        ),
      );

      await expectLater(
        backend.initialize(created.handle).timeout(const Duration(seconds: 5)),
        throwsA(
          isA<XVideoPlayerException>().having(
            (e) => e.code,
            'code',
            'decode_failed',
          ),
        ),
      );
    },
    // Android starts loading a video in initialize.
    skip: Platform.isAndroid,
  );

  testWidgets(
    'a speed set while paused holds once playback starts, and after a pause',
    (tester) async {
      final controller = XVideoPlayerController.file(
        await _assetFile('ten_seconds.mp4'),
      );
      addTearDown(controller.dispose);

      final speeds = await tester.runAsync(() async {
        await controller.initialize();
        await controller.setPlaybackSpeed(2);
        final speeds = <double>[];
        for (var run = 0; run < 2; run++) {
          await controller.play();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final from = controller.value.position;
          final clock = Stopwatch()..start();
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          speeds.add(
            (controller.value.position - from).inMicroseconds /
                clock.elapsedMicroseconds,
          );
          await controller.pause();
        }
        return speeds;
      });
      expect(speeds, everyElement(closeTo(2, 0.3)));
    },
  );
}

Future<File> _assetFile(String name) async {
  final video = await rootBundle.load('integration_test/assets/$name');
  return _tempFile(name, video.buffer.asUint8List());
}

Future<File> _tempFile(String name, List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp();
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file;
}

/// Serves one video over HTTP byte ranges and holds every response until
/// [release]. It runs in its own isolate, so it answers while the main
/// thread is blocked.
class _HeldVideoServer {
  _HeldVideoServer._(this._control, this.uri);

  final SendPort _control;
  final Uri uri;

  static Future<_HeldVideoServer> start(Uint8List bytes) async {
    final ready = ReceivePort();
    await Isolate.spawn(_serve, (ready.sendPort, bytes));
    final (SendPort control, int port) = await ready.first as (SendPort, int);
    return _HeldVideoServer._(
      control,
      Uri.parse('http://127.0.0.1:$port/v.mp4'),
    );
  }

  /// Whether any response has been sent.
  Future<bool> served() async {
    final reply = ReceivePort();
    _control.send(reply.sendPort);
    return await reply.first as bool;
  }

  void release() => _control.send('release');

  void close() => _control.send('close');
}

Future<void> _serve((SendPort, Uint8List) args) async {
  final (ready, bytes) = args;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final control = ReceivePort();
  final released = Completer<void>();
  var served = false;
  // Releases on its own so a create that waits for the header still returns.
  final fallback = Timer(const Duration(seconds: 10), released.complete);
  control.listen((message) {
    switch (message) {
      case SendPort reply:
        reply.send(served);
      case 'release':
        fallback.cancel();
        if (!released.isCompleted) released.complete();
      case 'close':
        fallback.cancel();
        control.close();
        server.close(force: true);
    }
  });
  ready.send((control.sendPort, server.port));

  server.listen((request) async {
    await released.future;
    served = true;
    final range = RegExp(r'bytes=(\d+)-(\d*)')
        .firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    final start = range == null ? 0 : int.parse(range[1]!);
    final end = range == null || range[2]!.isEmpty
        ? bytes.length - 1
        : min(int.parse(range[2]!), bytes.length - 1);
    final response = request.response
      ..statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent
      ..contentLength = end - start + 1;
    response.headers
      ..contentType = ContentType('video', 'mp4')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range != null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${bytes.length}',
      );
    }
    response.add(bytes.sublist(start, end + 1));
    await response.close();
  });
}
