import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/audio.dart';

Int16List _pcm(List<int> samples) => Int16List.fromList(samples);

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const methods = MethodChannel('ux/audio_sink');
  const events = MethodChannel('ux/audio_sink/events');

  group('MethodChannelXAudioSink.encodePcm', () {
    test('encodes little-endian Int16 samples', () {
      final bytes = MethodChannelXAudioSink.encodePcm(
        _pcm([0, 1, -1, 32767, -32768]),
      );
      final data = ByteData.view(bytes.buffer);
      expect(bytes, hasLength(10));
      expect(
        [for (var i = 0; i < 5; i++) data.getInt16(i * 2, Endian.little)],
        [0, 1, -1, 32767, -32768],
      );
    });

    test('an empty chunk encodes to no bytes', () {
      expect(MethodChannelXAudioSink.encodePcm(Int16List(0)), isEmpty);
    });
  });

  group('MethodChannelXAudioSink', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(events, (call) async => null);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
      debugDefaultTargetPlatformOverride = null;
    });

    Future<void> sendEvent(Object? event) => messenger.handlePlatformMessage(
      'ux/audio_sink/events',
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );

    List<String> methodNames() => [for (final call in calls) call.method];

    test('enqueue hands the platform little-endian PCM', () async {
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();

      await sink.enqueue(_pcm([16384, -16384]));

      expect(methodNames(), ['enqueue']);
      final bytes = calls.single.arguments as Uint8List;
      expect(bytes, [0x00, 0x40, 0x00, 0xC0]);
    });

    test('an empty chunk never reaches the platform', () async {
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();

      await sink.enqueue(Int16List(0));

      expect(calls, isEmpty);
    });

    test('a drained event reaches the stream', () async {
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();
      var drains = 0;
      sink.drained.listen((_) => drains++);

      await sendEvent({'type': 'drained'});
      await pumpEventQueue();
      expect(drains, 1);

      await sendEvent({'type': 'drained'});
      await pumpEventQueue();
      expect(drains, 2);
    });

    test('state events drive the state listenable', () async {
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();
      expect(sink.state.value, XAudioSinkState.idle);

      await sendEvent({'type': 'state', 'state': 'playing'});
      await pumpEventQueue();
      expect(sink.state.value, XAudioSinkState.playing);

      await sendEvent({'type': 'state', 'state': 'interrupted'});
      await pumpEventQueue();
      expect(sink.state.value, XAudioSinkState.interrupted);
    });

    test('an unknown state leaves the current one alone', () async {
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();
      await sendEvent({'type': 'state', 'state': 'playing'});
      await pumpEventQueue();

      await sendEvent({'type': 'state', 'state': 'zzz'});
      await pumpEventQueue();
      expect(sink.state.value, XAudioSinkState.playing);
    });

    test('concurrent chunks reach the platform one at a time', () async {
      final firstEnqueued = Completer<void>();
      final releaseFirst = Completer<void>();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (calls.length == 1) {
          firstEnqueued.complete();
          await releaseFirst.future;
        }
        return null;
      });
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();

      final first = sink.enqueue(_pcm([1]));
      await firstEnqueued.future;
      final second = sink.enqueue(_pcm([2]));
      await pumpEventQueue();
      expect(calls, hasLength(1));

      releaseFirst.complete();
      await Future.wait([first, second]);
      expect(calls, hasLength(2));
      expect((calls[1].arguments as Uint8List), [2, 0]);
    });

    test('flush cancels the chunks still waiting in Dart', () async {
      final firstEnqueued = Completer<void>();
      final releaseFirst = Completer<void>();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (calls.length == 1) {
          firstEnqueued.complete();
          await releaseFirst.future;
        }
        return null;
      });
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();

      final first = sink.enqueue(_pcm([1]));
      await firstEnqueued.future;
      final second = sink.enqueue(_pcm([2]));
      final flush = sink.flush();

      releaseFirst.complete();
      await Future.wait([first, second, flush]);

      expect(methodNames(), ['enqueue', 'flush']);
    });

    test('a chunk enqueued after flush plays', () async {
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();

      await sink.enqueue(_pcm([1]));
      await sink.flush();
      await sink.enqueue(_pcm([2]));

      expect(methodNames(), ['enqueue', 'flush', 'enqueue']);
      expect((calls.last.arguments as Uint8List), [2, 0]);
    });

    test('flush waits for an in-flight chunk', () async {
      final enqueueReachedPlatform = Completer<void>();
      final releaseEnqueue = Completer<void>();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (call.method == 'enqueue') {
          enqueueReachedPlatform.complete();
          await releaseEnqueue.future;
        }
        return null;
      });
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();

      final enqueue = sink.enqueue(_pcm([1]));
      await enqueueReachedPlatform.future;
      final flush = sink.flush();
      await pumpEventQueue();
      expect(methodNames(), ['enqueue']);

      releaseEnqueue.complete();
      await Future.wait([enqueue, flush]);
      expect(methodNames(), ['enqueue', 'flush']);
    });

    test('a failed command does not prevent the next command', () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (calls.length == 1) throw PlatformException(code: 'start_failed');
        return null;
      });
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();

      await expectLater(
        sink.enqueue(_pcm([1])),
        throwsA(isA<XAudioSinkException>()),
      );
      await sink.enqueue(_pcm([2]));

      expect(calls, hasLength(2));
    });

    test('a platform failure surfaces as XAudioSinkException', () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        throw PlatformException(
          code: 'no_output_device',
          message: '16 kHz mono PCM16 unavailable',
        );
      });
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();

      await expectLater(
        sink.enqueue(_pcm([1])),
        throwsA(
          isA<XAudioSinkException>()
              .having((e) => e.code, 'code', 'no_output_device')
              .having(
                (e) => e.message,
                'message',
                '16 kHz mono PCM16 unavailable',
              ),
        ),
      );
    });

    test('an unsupported platform never touches the channels', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final sink = MethodChannelXAudioSink();
      await pumpEventQueue();

      expect(calls, isEmpty);
      await expectLater(
        sink.enqueue(_pcm([1])),
        throwsA(
          isA<XAudioSinkException>().having(
            (e) => e.code,
            'code',
            'unsupported',
          ),
        ),
      );
      await sink.flush();
      expect(calls, isEmpty);
    });
  });
}
