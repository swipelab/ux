import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/log.dart';

void _noop() {}

MemorySink _installMemorySink({LogLevel minLevel = LogLevel.trace}) {
  final sink = MemorySink();
  Log.configure(minLevel: minLevel, sink: sink, captureCrashes: _noop);
  return sink;
}

void main() {
  group('LogLevel', () {
    test('numeric values align with package:logging', () {
      expect(LogLevel.trace.value, 500);
      expect(LogLevel.debug.value, 700);
      expect(LogLevel.info.value, 800);
      expect(LogLevel.warn.value, 900);
      expect(LogLevel.error.value, 1000);
      expect(LogLevel.fatal.value, 1200);
    });

    test('letters are distinct and uppercase', () {
      final letters = LogLevel.values.map((l) => l.letter).toSet();
      expect(letters.length, LogLevel.values.length);
      for (final l in letters) {
        expect(l, l.toUpperCase());
      }
    });
  });

  group('MemorySink', () {
    test('records events in order', () {
      final sink = _installMemorySink();
      Log.d('one');
      Log.i('two');
      Log.w('three');
      expect(sink.snapshot().map((r) => r.message).toList(), [
        'one',
        'two',
        'three',
      ]);
      expect(sink.snapshot().map((r) => r.level).toList(), [
        LogLevel.debug,
        LogLevel.info,
        LogLevel.warn,
      ]);
    });

    test('evicts oldest past capacity', () {
      final sink = MemorySink(capacity: 3);
      Log.configure(minLevel: LogLevel.trace, sink: sink);
      for (var i = 0; i < 5; i++) {
        Log.i('msg $i');
      }
      expect(sink.snapshot().map((r) => r.message).toList(), [
        'msg 2',
        'msg 3',
        'msg 4',
      ]);
    });

    test('snapshot is unmodifiable', () {
      final sink = _installMemorySink();
      Log.i('x');
      expect(() => sink.snapshot().clear(), throwsUnsupportedError);
    });

    test('clear empties the buffer', () {
      final sink = _installMemorySink();
      Log.i('x');
      sink.clear();
      expect(sink.snapshot(), isEmpty);
    });
  });

  group('level filtering', () {
    test('records below Log.minLevel are dropped', () {
      final sink = _installMemorySink(minLevel: LogLevel.warn);
      Log.t('trace');
      Log.d('debug');
      Log.i('info');
      Log.w('warn');
      Log.e('error');
      expect(sink.snapshot().map((r) => r.level).toList(), [
        LogLevel.warn,
        LogLevel.error,
      ]);
    });

    test('per-sink minLevel filters independently', () {
      final verbose = MemorySink();
      final errorsOnly = MemorySink(minLevel: LogLevel.error);
      Log.configure(minLevel: LogLevel.trace, sink: verbose + errorsOnly);

      Log.i('info');
      Log.e('error');

      expect(verbose.snapshot().map((r) => r.message), ['info', 'error']);
      expect(errorsOnly.snapshot().map((r) => r.message), ['error']);
    });
  });

  group('lazy messages', () {
    test('thunk is not invoked when filtered', () {
      _installMemorySink(minLevel: LogLevel.warn);
      var called = 0;
      Log.d(() {
        called++;
        return 'expensive';
      });
      expect(called, 0);
    });

    test('thunk is invoked and rendered when enabled', () {
      final sink = _installMemorySink();
      var called = 0;
      Log.d(() {
        called++;
        return 'computed';
      });
      expect(called, 1);
      expect(sink.snapshot().single.message, 'computed');
    });
  });

  group('tagging', () {
    test('Log.tag sets the record tag', () {
      final sink = _installMemorySink();
      Log.tag('KB').i('hello');
      expect(sink.snapshot().single.tag, 'KB');
    });

    test('root logger emits with null tag', () {
      final sink = _installMemorySink();
      Log.i('rootless');
      expect(sink.snapshot().single.tag, isNull);
    });

    test('nested tag joins with a dot', () {
      final sink = _installMemorySink();
      Log.tag('A').tag('B').i('x');
      expect(sink.snapshot().single.tag, 'A.B');
    });
  });

  group('errors and stack traces', () {
    test('error and stack pass through to the record', () {
      final sink = _installMemorySink();
      final err = Exception('boom');
      final st = StackTrace.current;
      Log.e('fail', error: err, stackTrace: st);
      final r = sink.snapshot().single;
      expect(r.error, same(err));
      expect(r.stackTrace, same(st));
    });

    test('fields pass through', () {
      final sink = _installMemorySink();
      Log.i('hit', fields: {'userId': 42, 'path': '/x'});
      expect(sink.snapshot().single.fields, {'userId': 42, 'path': '/x'});
    });
  });

  group('dedupe via crash handler', () {
    test('FlutterError.onError skips an error already seen by Log.e', () {
      final prevFlutter = FlutterError.onError;
      addTearDown(() => FlutterError.onError = prevFlutter);

      final sink = MemorySink();
      Log.configure(minLevel: LogLevel.trace, sink: sink);

      final err = Exception('once');
      Log.e('caught', error: err);
      FlutterError.onError!(FlutterErrorDetails(exception: err));

      expect(sink.snapshot().map((r) => r.message), ['caught']);
    });

    test('FlutterError.onError still reports a fresh error', () {
      final prevFlutter = FlutterError.onError;
      addTearDown(() => FlutterError.onError = prevFlutter);

      final sink = MemorySink();
      Log.configure(minLevel: LogLevel.trace, sink: sink);

      FlutterError.onError!(FlutterErrorDetails(exception: Exception('new')));

      expect(sink.snapshot().single.level, LogLevel.error);
      expect(sink.snapshot().single.error, isA<Exception>());
    });
  });

  group('clock', () {
    test('record time comes from package:clock', () {
      final sink = _installMemorySink();
      final fixed = DateTime.utc(2026, 1, 2, 3, 4, 5, 678);
      withClock(Clock.fixed(fixed), () {
        Log.i('pinned');
      });
      expect(sink.snapshot().single.time, fixed);
    });
  });

  group('composite sink', () {
    test('chained + flattens into a single composite', () {
      final a = MemorySink();
      final b = MemorySink();
      final c = MemorySink();
      Log.configure(minLevel: LogLevel.trace, sink: a + b + c);
      Log.i('fan');
      expect(a.snapshot().single.message, 'fan');
      expect(b.snapshot().single.message, 'fan');
      expect(c.snapshot().single.message, 'fan');
    });

    test('a throwing sink does not stop others', () {
      final recorded = MemorySink();
      final bomb = _ThrowingSink();
      Log.configure(minLevel: LogLevel.trace, sink: bomb + recorded);
      Log.i('survive');
      expect(recorded.snapshot().single.message, 'survive');
    });
  });

  group('ConsoleSink formatting', () {
    test('writes a single line with level letter and message', () {
      final lines = <String>[];
      Log.configure(
        minLevel: LogLevel.trace,
        sink: ConsoleSink(color: false, write: lines.add),
      );
      withClock(Clock.fixed(DateTime.utc(2026, 1, 1, 12, 34, 56, 789)), () {
        Log.tag('T').i('hello');
      });
      expect(lines.single, contains('12:34:56.789'));
      expect(lines.single, contains(' I '));
      expect(lines.single, contains('T hello'));
    });

    test('renders fields inline', () {
      final lines = <String>[];
      Log.configure(
        minLevel: LogLevel.trace,
        sink: ConsoleSink(color: false, write: lines.add),
      );
      Log.i('hit', fields: {'n': 3});
      expect(lines.single, contains('{n: 3}'));
    });

    test('renders error on a follow-up line', () {
      final lines = <String>[];
      Log.configure(
        minLevel: LogLevel.trace,
        sink: ConsoleSink(color: false, write: lines.add),
      );
      Log.e('oops', error: Exception('bad'));
      expect(lines.single.split('\n').length, greaterThan(1));
      expect(lines.single, contains('└─ Exception: bad'));
    });

    test('caps stack frames', () {
      final lines = <String>[];
      Log.configure(
        minLevel: LogLevel.trace,
        sink: ConsoleSink(color: false, stackFrames: 2, write: lines.add),
      );
      final longStack = StackTrace.fromString(
        List.generate(10, (i) => '#$i  frame$i').join('\n'),
      );
      Log.e('x', error: Exception('e'), stackTrace: longStack);
      final stackLines = lines.single
          .split('\n')
          .where((l) => l.contains('#'))
          .toList();
      expect(stackLines.length, 2);
    });
  });
}

class _ThrowingSink extends LogSink {
  @override
  LogLevel get minLevel => LogLevel.trace;

  @override
  void emit(LogRecord record) => throw StateError('no');
}
