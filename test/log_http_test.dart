import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ux/log.dart';

void main() {
  group('HttpSink', () {
    final endpoint = Uri.parse('http://test.invalid/log');

    test('emit serializes record to JSON envelope', () async {
      List<List<int>>? captured;
      String? capturedToken;
      final sink = HttpSink(
        endpoint: endpoint,
        token: 'abc',
        flushInterval: const Duration(milliseconds: 1),
        device: {'platform': 'ios'},
        app: {'version': '1.8.0', 'buildNumber': 11},
        sender: (url, token, body) async {
          captured ??= [];
          captured!.add(body);
          capturedToken = token;
          return 204;
        },
      );

      sink.emit(
        LogRecord(
          time: DateTime.utc(2026, 5, 10, 12, 0, 0),
          level: LogLevel.error,
          message: 'boom',
          tag: 'net',
          fields: {
            'k': 1,
            'nested': {'x': true},
          },
          error: StateError('bad'),
          stackTrace: StackTrace.fromString('frame'),
        ),
      );
      await sink.flush();

      expect(capturedToken, 'abc');
      expect(captured, isNotNull);
      expect(captured!.length, 1);
      final batch = jsonDecode(utf8.decode(captured!.single)) as List;
      expect(batch.length, 1);
      final rec = batch.single as Map<String, Object?>;
      expect(rec['time'], '2026-05-10T12:00:00.000Z');
      expect(rec['level'], 'E');
      expect(rec['tag'], 'net');
      expect(rec['message'], 'boom');
      expect(rec['fields'], {
        'k': 1,
        'nested': {'x': true},
      });
      expect(rec['error'], contains('bad'));
      expect(rec['stackTrace'], 'frame');
      expect(rec['device'], {'platform': 'ios'});
      expect(rec['app'], {'version': '1.8.0', 'buildNumber': 11});
    });

    test('batches up to batchSize before flushing', () async {
      final batches = <int>[];
      final sink = HttpSink(
        endpoint: endpoint,
        token: 't',
        batchSize: 3,
        flushInterval: const Duration(seconds: 60),
        sender: (url, token, body) async {
          final list = jsonDecode(utf8.decode(body)) as List;
          batches.add(list.length);
          return 204;
        },
      );

      for (var i = 0; i < 5; i++) {
        sink.emit(
          LogRecord(
            time: DateTime.utc(2026, 5, 10),
            level: LogLevel.info,
            message: 'm$i',
          ),
        );
      }
      await sink.flush();
      // First batch of 3 fires at batchSize; flush ships the remaining 2.
      expect(batches, [3, 2]);
    });

    test('retries on 5xx with exponential backoff', () async {
      final attempts = <DateTime>[];
      final sink = HttpSink(
        endpoint: endpoint,
        token: 't',
        flushInterval: const Duration(milliseconds: 1),
        initialBackoff: const Duration(milliseconds: 10),
        maxBackoff: const Duration(milliseconds: 200),
        sender: (url, token, body) async {
          attempts.add(DateTime.now());
          if (attempts.length < 4) return 503;
          return 204;
        },
      );

      sink.emit(
        LogRecord(
          time: DateTime.utc(2026, 5, 10),
          level: LogLevel.info,
          message: 'retry-me',
        ),
      );
      await sink.flush();

      expect(attempts.length, 4);
      // 10ms → 20ms → 40ms gaps (within maxBackoff cap of 200ms). Each gap
      // should be roughly double the prior, but we leave slack for scheduler
      // jitter and just assert monotonically non-decreasing positive gaps.
      final gap1 = attempts[1].difference(attempts[0]).inMicroseconds;
      final gap2 = attempts[2].difference(attempts[1]).inMicroseconds;
      final gap3 = attempts[3].difference(attempts[2]).inMicroseconds;
      expect(gap1, greaterThan(0));
      expect(gap2, greaterThanOrEqualTo(gap1));
      expect(gap3, greaterThanOrEqualTo(gap2));
    });

    test('drops batch on 4xx after one warning', () async {
      var calls = 0;
      final sink = HttpSink(
        endpoint: endpoint,
        token: 't',
        flushInterval: const Duration(milliseconds: 1),
        sender: (url, token, body) async {
          calls += 1;
          return 400;
        },
      );

      sink.emit(
        LogRecord(
          time: DateTime.utc(2026, 5, 10),
          level: LogLevel.info,
          message: 'bad',
        ),
      );
      await sink.flush();

      // Hit once and gave up — no retry on 4xx.
      expect(calls, 1);
    });

    test('queue overflow drops oldest', () async {
      final shipped = <String>[];
      final sender = Completer<void>();
      var ready = false;

      final sink = HttpSink(
        endpoint: endpoint,
        token: 't',
        batchSize: 1000,
        flushInterval: const Duration(seconds: 60),
        queueCapacity: 3,
        sender: (url, token, body) async {
          if (!ready) await sender.future;
          final batch = jsonDecode(utf8.decode(body)) as List;
          for (final m in batch) {
            shipped.add(((m as Map)['message']) as String);
          }
          return 204;
        },
      );

      for (var i = 0; i < 5; i++) {
        sink.emit(
          LogRecord(
            time: DateTime.utc(2026, 5, 10),
            level: LogLevel.info,
            message: 'm$i',
          ),
        );
      }
      ready = true;
      sender.complete();
      await sink.flush();

      // First 2 dropped (queue cap 3), so only m2..m4 ship.
      expect(shipped, ['m2', 'm3', 'm4']);
    });

    test('default sender hits a real loopback HTTP server', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = <Map<String, Object?>>[];
      final tokens = <String?>[];
      unawaited(() async {
        await for (final req in server) {
          tokens.add(req.headers.value(HttpHeaders.authorizationHeader));
          final body = await utf8.decoder.bind(req).join();
          final list = jsonDecode(body) as List;
          for (final r in list) {
            received.add((r as Map).cast<String, Object?>());
          }
          req.response.statusCode = 204;
          await req.response.close();
        }
      }());

      final sink = HttpSink(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/log'),
        token: 'sek',
        flushInterval: const Duration(milliseconds: 1),
      );
      sink.emit(
        LogRecord(
          time: DateTime.utc(2026, 5, 10, 12, 0, 0),
          level: LogLevel.info,
          message: 'roundtrip',
        ),
      );
      await sink.flush();
      await server.close(force: true);

      expect(tokens, ['Bearer sek']);
      expect(received.length, 1);
      expect(received.single['message'], 'roundtrip');
      expect(received.single['level'], 'I');
    });

    test('fields with non-encodable values are stringified', () async {
      Map<String, Object?>? rec;
      final sink = HttpSink(
        endpoint: endpoint,
        token: 't',
        flushInterval: const Duration(milliseconds: 1),
        sender: (url, token, body) async {
          final list = jsonDecode(utf8.decode(body)) as List;
          rec = (list.single as Map).cast<String, Object?>();
          return 204;
        },
      );

      sink.emit(
        LogRecord(
          time: DateTime.utc(2026, 5, 10),
          level: LogLevel.info,
          message: 'm',
          fields: {'when': DateTime.utc(2026, 5, 10, 1, 2, 3)},
        ),
      );
      await sink.flush();

      expect(rec!['fields'], {'when': '2026-05-10 01:02:03.000Z'});
    });
  });
}
