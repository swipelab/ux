import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/secure_store.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const methods = MethodChannel('ux/secure_store');

  final calls = <MethodCall>[];
  final values = <String, String>{};

  /// Completes the pending platform call when set, so a test can hold a
  /// command open and watch what the next one does meanwhile.
  Completer<void>? gate;

  setUp(() {
    calls.clear();
    values.clear();
    gate = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      await gate?.future;
      final args = (call.arguments as Map).cast<String, Object?>();
      final key = args['key'] as String;
      switch (call.method) {
        case 'read':
          return values[key];
        case 'write':
          values[key] = args['value'] as String;
          return null;
        case 'delete':
          values.remove(key);
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('a value written under a key reads back', () async {
    final store = MethodChannelXSecureStore();

    await store.write('session', 'token-1');

    expect(await store.read('session'), 'token-1');
    expect(calls.map((c) => c.method), ['write', 'read']);
    expect(calls.first.arguments, {'key': 'session', 'value': 'token-1'});
  });

  test('a key that holds nothing reads null', () async {
    expect(await MethodChannelXSecureStore().read('absent'), isNull);
  });

  test('a deleted key reads null', () async {
    final store = MethodChannelXSecureStore();
    await store.write('session', 'token-1');

    await store.delete('session');

    expect(await store.read('session'), isNull);
    expect(calls.last.arguments, {'key': 'session'});
  });

  test('commands reach the platform in call order', () async {
    final store = MethodChannelXSecureStore();
    gate = Completer<void>();

    final write = store.write('session', 'token-1');
    final read = store.read('session');
    await pumpEventQueue();
    // The read is queued behind the write rather than racing it.
    expect(calls.map((c) => c.method), ['write']);

    gate!.complete();
    await write;

    expect(await read, 'token-1');
  });

  test('a failing command does not strand the ones behind it', () async {
    final store = MethodChannelXSecureStore();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'write') {
        throw PlatformException(
          code: 'store_failed',
          message: 'OSStatus -25299',
        );
      }
      return null;
    });

    await expectLater(
      store.write('session', 'token-1'),
      throwsA(
        isA<XSecureStoreException>()
            .having((e) => e.code, 'code', 'store_failed')
            .having((e) => e.message, 'message', 'OSStatus -25299'),
      ),
    );
    expect(await store.read('session'), isNull);
  });

  test('a platform without a store refuses every command', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final store = MethodChannelXSecureStore();

    expect(store.supported, isFalse);
    for (final command in [
      () => store.read('session'),
      () => store.write('session', 'token-1'),
      () => store.delete('session'),
    ]) {
      await expectLater(
        command(),
        throwsA(
          isA<XSecureStoreException>().having(
            (e) => e.code,
            'code',
            'unsupported',
          ),
        ),
      );
    }
    expect(calls, isEmpty);
  });
}
