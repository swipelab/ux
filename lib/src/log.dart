/// Pretty, production-ready logger.
///
/// Static entry point [Log] for ad-hoc calls; [Log.tag] for scoped [Logger]s.
/// Sinks fan out via `+`. Crash capture via [Log.installCrashHandlers].
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show stderr, stdout;
import 'dart:isolate';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

/// Severity. Numeric values align with `package:logging` so DevTools filters
/// map 1:1.
enum LogLevel {
  /// Finest-grained tracing. Typically disabled in every build.
  trace(500, 'T'),

  /// Developer diagnostics. Default minimum in debug builds.
  debug(700, 'D'),

  /// Normal operational events.
  info(800, 'I'),

  /// Something unexpected but recoverable. Default minimum in release.
  warn(900, 'W'),

  /// A failure that the app kept running through.
  error(1000, 'E'),

  /// A failure that the app may not recover from.
  fatal(1200, 'F');

  const LogLevel(this.value, this.letter);

  /// Numeric severity matching `package:logging` / `dart:developer`.
  final int value;

  /// Single-character label used in console output.
  final String letter;
}

/// A single log event passed to [LogSink.emit].
class LogRecord {
  /// Creates a record. Callers are [Logger] / [Log]; most users never construct.
  LogRecord({
    required this.time,
    required this.level,
    required this.message,
    this.tag,
    this.error,
    this.stackTrace,
    this.fields,
  });

  /// Wall-clock time at emit, taken from `package:clock`.
  final DateTime time;

  /// Severity.
  final LogLevel level;

  /// Rendered message text. Lazy thunks are resolved before construction.
  final String message;

  /// Scope name from [Log.tag] / [Logger.tag], if any.
  final String? tag;

  /// Associated error object, if one was passed.
  final Object? error;

  /// Stack trace captured at the call site, if one was passed.
  final StackTrace? stackTrace;

  /// Structured key/value pairs for this record.
  final Map<String, Object?>? fields;
}

/// Destination for emitted records. Implementations must not throw; they
/// swallow their own errors so one failing sink cannot take down the pipeline.
abstract class LogSink {
  /// Subclass constructor.
  const LogSink();

  /// Records below this level are dropped before [emit].
  LogLevel get minLevel;

  /// Delivers [record]. Must not throw.
  void emit(LogRecord record);

  /// Awaits any pending delivery. Override for buffered sinks.
  Future<void> flush() async {}

  /// Fan out to `this` then `other`. Each sink applies its own [minLevel].
  LogSink operator +(LogSink other) {
    final left = this is _CompositeSink
        ? (this as _CompositeSink)._sinks
        : [this];
    final right = other is _CompositeSink ? other._sinks : [other];
    return _CompositeSink([...left, ...right]);
  }
}

class _CompositeSink extends LogSink {
  _CompositeSink(this._sinks);

  final List<LogSink> _sinks;

  @override
  LogLevel get minLevel => _sinks
      .map((s) => s.minLevel)
      .reduce((a, b) => a.value < b.value ? a : b);

  @override
  void emit(LogRecord r) {
    for (final s in _sinks) {
      if (r.level.value < s.minLevel.value) continue;
      try {
        s.emit(r);
      } catch (_) {}
    }
  }

  @override
  Future<void> flush() async {
    for (final s in _sinks) {
      try {
        await s.flush();
      } catch (_) {}
    }
  }
}

/// Scoped logger. Obtain via [Log.tag].
class Logger {
  Logger._(this.name);

  /// Tag prefix applied to every record from this logger. Empty for the root.
  final String name;

  /// Returns a child logger whose [name] is `this.name.child`.
  Logger tag(String child) => Logger._(name.isEmpty ? child : '$name.$child');

  /// Logs at [LogLevel.trace].
  void t(Object message, {Map<String, Object?>? fields}) =>
      _log(LogLevel.trace, message, fields: fields);

  /// Logs at [LogLevel.debug].
  void d(Object message, {Map<String, Object?>? fields}) =>
      _log(LogLevel.debug, message, fields: fields);

  /// Logs at [LogLevel.info].
  void i(Object message, {Map<String, Object?>? fields}) =>
      _log(LogLevel.info, message, fields: fields);

  /// Logs at [LogLevel.warn].
  void w(
    Object message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _log(
    LogLevel.warn,
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  /// Logs at [LogLevel.error].
  void e(
    Object message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _log(
    LogLevel.error,
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  /// Logs at [LogLevel.fatal].
  void f(
    Object message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _log(
    LogLevel.fatal,
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  void _log(
    LogLevel level,
    Object message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.value < Log._minLevel.value) return;
    final text = message is Function
        ? '${(message as Function)()}'
        : '$message';
    Log._markReported(error);
    final record = LogRecord(
      time: clock.now(),
      level: level,
      message: text,
      tag: name.isEmpty ? null : name,
      error: error,
      stackTrace: stackTrace,
      fields: fields,
    );
    try {
      Log._sink.emit(record);
    } catch (_) {}
  }
}

/// Global entry point for logging.
class Log {
  Log._();

  static final Logger _root = Logger._('');
  static LogSink _sink = const NoopSink();
  static LogLevel _minLevel = kReleaseMode ? LogLevel.warn : LogLevel.debug;
  static final Expando<bool> _reported = Expando<bool>('ux.log.reported');

  /// The lowest level that will reach any sink.
  static LogLevel get minLevel => _minLevel;

  /// The sink currently receiving records (composite if `+` was used).
  static LogSink get sink => _sink;

  /// Configures the global logger.
  ///
  /// By default, invokes [captureCrashes] so uncaught Flutter / async /
  /// isolate errors flow through [e]. Pass a different hook (or `() {}` for
  /// no-op) to customise: test environments or apps that own
  /// `FlutterError.onError` should pass a no-op.
  static void configure({
    LogLevel? minLevel,
    LogSink? sink,
    VoidCallback captureCrashes = Log.captureCrashes,
  }) {
    if (minLevel != null) _minLevel = minLevel;
    if (sink != null) _sink = sink;
    captureCrashes();
  }

  /// Returns a scoped [Logger] that tags every record with [name].
  static Logger tag(String name) => Logger._(name);

  /// Logs at [LogLevel.trace].
  static void t(Object message, {Map<String, Object?>? fields}) =>
      _root.t(message, fields: fields);

  /// Logs at [LogLevel.debug].
  static void d(Object message, {Map<String, Object?>? fields}) =>
      _root.d(message, fields: fields);

  /// Logs at [LogLevel.info].
  static void i(Object message, {Map<String, Object?>? fields}) =>
      _root.i(message, fields: fields);

  /// Logs at [LogLevel.warn].
  static void w(
    Object message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _root.w(
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  /// Logs at [LogLevel.error].
  static void e(
    Object message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _root.e(
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  /// Logs at [LogLevel.fatal].
  static void f(
    Object message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _root.f(
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  /// Awaits pending delivery on the active sink. Call before exiting the
  /// isolate or after logging a fatal error that may terminate the app.
  static Future<void> flush() => _sink.flush();

  /// Routes [FlutterError.onError], [PlatformDispatcher]'s `onError`, and
  /// isolate errors through [e]. Invoked by [configure] by default.
  ///
  /// Errors seen previously by [e]/[w]/[f] (caught, logged, rethrown) are
  /// suppressed here via an [Expando] mark, so `try {...} catch (err) { Log.e(
  /// ..., error: err); rethrow; }` does not double-report.
  static void captureCrashes() {
    FlutterError.onError = (details) {
      if (_isReported(details.exception)) return;
      e(
        details.exceptionAsString(),
        error: details.exception,
        stackTrace: details.stack,
        fields: {
          if (details.library != null) 'library': details.library,
          if (details.context != null) 'context': details.context.toString(),
        },
      );
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      if (_isReported(error)) return true;
      e('uncaught async', error: error, stackTrace: stack);
      return true;
    };
    Isolate.current.addErrorListener(
      RawReceivePort((dynamic pair) {
        final list = pair as List;
        e(
          'isolate error: ${list[0]}',
          stackTrace: StackTrace.fromString('${list[1]}'),
        );
      }).sendPort,
    );
  }

  static bool _canTag(Object? o) =>
      o != null && o is! num && o is! String && o is! bool;

  static bool _isReported(Object? o) => _canTag(o) && _reported[o!] == true;

  static void _markReported(Object? o) {
    if (_canTag(o)) _reported[o!] = true;
  }
}

// ─── sinks ────────────────────────────────────────────────────────────────

/// Discards everything. Default until [Log.configure] is called.
class NoopSink extends LogSink {
  /// Creates a sink that drops every record.
  const NoopSink();

  @override
  LogLevel get minLevel => LogLevel.fatal;

  @override
  void emit(LogRecord record) {}
}

/// ANSI-colored single-line output to stderr (or a custom writer).
class ConsoleSink extends LogSink {
  /// Creates a console sink. Set [color] explicitly for tests or non-tty
  /// writers; otherwise it's auto-detected from `stdout.supportsAnsiEscapes`.
  /// [stackFrames] caps how many stack lines are printed per record.
  ConsoleSink({
    this._minLevel = LogLevel.trace,
    bool? color,
    this.stackFrames = 8,
    void Function(String line)? write,
  }) : _color = color ?? _detectAnsi(),
       _write = write ?? _defaultConsoleWrite;

  final LogLevel _minLevel;
  final bool _color;

  /// Maximum stack-trace lines printed beneath an error. Extras are dropped.
  final int stackFrames;
  final void Function(String) _write;

  @override
  LogLevel get minLevel => _minLevel;

  @override
  void emit(LogRecord r) {
    _write(_formatRecord(r, _color, stackFrames));
  }
}

/// Forwards to `dart:developer.log`. Silent in release on non-web (VM service
/// not attached); active on web where it routes to the browser console.
class DeveloperSink extends LogSink {
  /// Creates a sink that hands records to `dart:developer.log`.
  DeveloperSink({this._minLevel = LogLevel.trace});

  final LogLevel _minLevel;

  @override
  LogLevel get minLevel => _minLevel;

  @override
  void emit(LogRecord r) {
    if (kReleaseMode && !kIsWeb) return;
    developer.log(
      r.message,
      time: r.time,
      level: r.level.value,
      name: r.tag ?? 'ux',
      error: r.error,
      stackTrace: r.stackTrace,
    );
  }
}

/// In-memory ring buffer. Useful as breadcrumbs for a crash reporter or as a
/// deterministic sink in tests.
class MemorySink extends LogSink {
  /// Creates a ring buffer that keeps the most recent [capacity] records.
  MemorySink({this.capacity = 100, this._minLevel = LogLevel.trace});

  /// Maximum number of records kept. Older records are evicted FIFO.
  final int capacity;
  final LogLevel _minLevel;
  final List<LogRecord> _records = [];

  @override
  LogLevel get minLevel => _minLevel;

  @override
  void emit(LogRecord r) {
    _records.add(r);
    if (_records.length > capacity) _records.removeAt(0);
  }

  /// Unmodifiable view of the current buffer, oldest first.
  List<LogRecord> snapshot() => List.unmodifiable(_records);

  /// Drops all buffered records.
  void clear() => _records.clear();
}

// ─── formatting ───────────────────────────────────────────────────────────

bool _detectAnsi() {
  if (kIsWeb) return false;
  try {
    return stdout.supportsAnsiEscapes;
  } catch (_) {
    return false;
  }
}

void _defaultConsoleWrite(String line) {
  if (kIsWeb) {
    developer.log(line, name: 'ux');
    return;
  }
  stderr.writeln(line);
}

const _ansiReset = '\x1B[0m';
const _ansiDim = '\x1B[2m';
const _ansiBold = '\x1B[1m';

String _colored(String s, int code, bool on) =>
    on ? '\x1B[${code}m$s$_ansiReset' : s;

String _dim(String s, bool on) => on ? '$_ansiDim$s$_ansiReset' : s;

String _bold(String s, bool on) => on ? '$_ansiBold$s$_ansiReset' : s;

int _levelColor(LogLevel l) {
  switch (l) {
    case LogLevel.trace:
      return 90;
    case LogLevel.debug:
      return 36;
    case LogLevel.info:
      return 32;
    case LogLevel.warn:
      return 33;
    case LogLevel.error:
      return 31;
    case LogLevel.fatal:
      return 35;
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
      '.${three(t.millisecond)}';
}

String _formatFields(Map<String, Object?> fields) {
  final buf = StringBuffer('{');
  var first = true;
  fields.forEach((k, v) {
    if (!first) buf.write(', ');
    buf
      ..write(k)
      ..write(': ')
      ..write(v);
    first = false;
  });
  buf.write('}');
  return buf.toString();
}

String _formatRecord(LogRecord r, bool color, int stackFrames) {
  final buf = StringBuffer()
    ..write(_dim(_formatTime(r.time), color))
    ..write(' ')
    ..write(_colored(r.level.letter, _levelColor(r.level), color))
    ..write(' ');
  if (r.tag != null) {
    buf
      ..write(_bold(r.tag!, color))
      ..write(' ');
  }
  buf.write(r.message);
  if (r.fields != null && r.fields!.isNotEmpty) {
    buf
      ..write('  ')
      ..write(_dim(_formatFields(r.fields!), color));
  }
  if (r.error != null) {
    buf
      ..write('\n   └─ ')
      ..write(_colored('${r.error}', _levelColor(r.level), color));
  }
  if (r.stackTrace != null) {
    final frames = r.stackTrace!
        .toString()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .take(stackFrames);
    for (final f in frames) {
      buf
        ..write('\n      ')
        ..write(_dim(f, color));
    }
  }
  return buf.toString();
}
