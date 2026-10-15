/// HTTP log sink — ships [LogRecord]s to a self-hosted endpoint.
///
/// Composes with the rest of the sink chain via [Log.configure]:
/// `Log.configure(sink: ConsoleSink() + HttpSink(endpoint: ..., token: ...))`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'log.dart';

/// Sends batched JSON records to an HTTP endpoint that accepts
/// `POST <endpoint>/log` with `Content-Type: application/json` and an
/// `Authorization: Bearer <token>` header. See `tools/log_server` for the
/// reference receiver.
class HttpSink extends LogSink {
  /// Creates a sink that POSTs batched records to [endpoint] with bearer
  /// [token] auth. [device] and [app] are merged into every record's JSON
  /// envelope. [sender] is overridable for tests.
  HttpSink({
    required this._endpoint,
    required this._token,
    this._minLevel = LogLevel.info,
    this.batchSize = 25,
    this.flushInterval = const Duration(seconds: 2),
    this.queueCapacity = 2000,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this._device,
    this._app,
    HttpSender? sender,
  }) : _sender = sender ?? _defaultSender;

  /// The full URL the batched POST hits (e.g. `http://nas:8000/log`).
  final Uri _endpoint;
  final String _token;
  final LogLevel _minLevel;
  final Map<String, Object?>? _device;
  final Map<String, Object?>? _app;
  final HttpSender _sender;

  /// Flush when the queue reaches this many records.
  final int batchSize;

  /// Flush at most this long after the first queued record.
  final Duration flushInterval;

  /// Hard cap. Beyond this, oldest records are dropped on each new `emit`.
  final int queueCapacity;

  /// First retry delay; doubles each attempt up to [maxBackoff].
  final Duration initialBackoff;

  /// Retry backoff cap. Starts at [initialBackoff], doubles, clamped here.
  final Duration maxBackoff;

  final Queue<Map<String, Object?>> _queue = Queue();
  Timer? _timer;
  Future<void>? _inFlight;
  bool _overflowWarned = false;

  @override
  LogLevel get minLevel => _minLevel;

  @override
  void emit(LogRecord record) {
    if (_queue.length >= queueCapacity) {
      _queue.removeFirst();
      if (!_overflowWarned) {
        _overflowWarned = true;
        developer.log(
          'HttpSink: queue at capacity ($queueCapacity), dropping oldest',
          name: 'ux.log',
        );
      }
    }
    _queue.add(_serialize(record));
    if (_queue.length >= batchSize) {
      _kick();
    } else {
      _timer ??= Timer(flushInterval, _kick);
    }
  }

  @override
  Future<void> flush() async {
    _kick();
    while (_inFlight != null) {
      await _inFlight;
    }
  }

  void _kick() {
    _timer?.cancel();
    _timer = null;
    if (_queue.isEmpty || _inFlight != null) return;
    final batch = List<Map<String, Object?>>.from(_queue);
    _queue.clear();
    _inFlight = _ship(batch).whenComplete(() {
      _inFlight = null;
      if (_queue.isNotEmpty) _kick();
    });
  }

  Future<void> _ship(List<Map<String, Object?>> batch) async {
    final body = utf8.encode(jsonEncode(batch));
    var backoff = initialBackoff;
    while (true) {
      int? status;
      try {
        status = await _sender(_endpoint, _token, body);
      } catch (_) {
        // Network error — treat like 5xx and retry.
      }
      if (status != null && status >= 200 && status < 300) return;
      if (status != null && status >= 400 && status < 500) {
        developer.log(
          'HttpSink: dropped ${batch.length} record(s); server returned $status',
          name: 'ux.log',
        );
        return;
      }
      await Future.delayed(backoff);
      backoff = backoff * 2;
      if (backoff > maxBackoff) backoff = maxBackoff;
    }
  }

  Map<String, Object?> _serialize(LogRecord r) => {
    'time': r.time.toUtc().toIso8601String(),
    'level': r.level.letter,
    if (r.tag != null) 'tag': r.tag,
    'message': r.message,
    if (r.fields != null && r.fields!.isNotEmpty) 'fields': _jsonify(r.fields!),
    if (r.error != null) 'error': r.error.toString(),
    if (r.stackTrace != null) 'stackTrace': r.stackTrace.toString(),
    if (_device != null) 'device': _device,
    if (_app != null) 'app': _app,
  };

  static Object? _jsonify(Object? v) {
    if (v == null || v is num || v is bool || v is String) return v;
    if (v is Map) {
      return {for (final e in v.entries) e.key.toString(): _jsonify(e.value)};
    }
    if (v is Iterable) return v.map(_jsonify).toList();
    return v.toString();
  }
}

/// Pluggable transport — return the HTTP status of the POST, or throw on
/// network failure. The default uses `dart:io.HttpClient`.
typedef HttpSender = Future<int> Function(
  Uri endpoint,
  String token,
  List<int> body,
);

Future<int> _defaultSender(Uri endpoint, String token, List<int> body) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(endpoint);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.add(body);
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  } finally {
    client.close(force: false);
  }
}
