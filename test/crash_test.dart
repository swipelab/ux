import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/crash.dart';
import 'package:ux/log.dart';

void _noop() {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('ux/crash');

  setUp(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('drainAndReport re-emits records as Log.f and acks each id', () async {
    final sink = MemorySink();
    Log.configure(sink: sink, minLevel: LogLevel.trace, captureCrashes: _noop);

    final acked = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'drainPending':
          return <Map<Object?, Object?>>[
            {
              'id': 'A',
              'platform': 'ios',
              'name': 'NSInvalidArgumentException',
              'reason': 'bad index',
              'callStackSymbols': <Object?>['0 frame'],
              'bundleId': 'im.bl.app',
            },
            {
              'id': 'B',
              'platform': 'android',
              'type': 'java.lang.RuntimeException',
              'message': 'boom',
              'stack': 'at Foo.bar()\nat Baz.qux()',
              'sdkInt': 34,
            },
          ];
        case 'ackCrash':
          acked.add(call.arguments as String);
          return null;
      }
      return null;
    });

    await XCrash.drainAndReport();

    final records = sink.snapshot();
    expect(records.length, 2);
    expect(records[0].level, LogLevel.fatal);
    expect(records[0].tag, 'ux.crash');
    expect(records[0].message, contains('NSInvalidArgumentException'));
    expect(records[0].message, contains('bad index'));
    expect(records[0].stackTrace.toString(), '0 frame');
    expect(records[0].fields?['platform'], 'ios');
    expect(records[0].fields?['bundleId'], 'im.bl.app');

    expect(records[1].message, contains('java.lang.RuntimeException'));
    expect(records[1].message, contains('boom'));
    expect(records[1].stackTrace.toString(), contains('Foo.bar()'));
    expect(records[1].fields?['sdkInt'], 34);

    expect(acked, ['A', 'B']);
  });

  test('drainAndReport tolerates MissingPluginException', () async {
    final sink = MemorySink();
    Log.configure(sink: sink, minLevel: LogLevel.trace, captureCrashes: _noop);

    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });

    await XCrash.drainAndReport();

    expect(sink.snapshot(), isEmpty);
  });

  test('drainAndReport logs but does not throw on channel errors', () async {
    final sink = MemorySink();
    Log.configure(sink: sink, minLevel: LogLevel.trace, captureCrashes: _noop);

    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'oops');
    });

    await XCrash.drainAndReport();

    expect(sink.snapshot().length, 1);
    expect(sink.snapshot().single.level, LogLevel.warn);
    expect(sink.snapshot().single.message, contains('drainPending'));
  });
}
