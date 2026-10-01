import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/services.dart';
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
    expect(metadata.rotationQuarterTurns, 1);
  });
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
