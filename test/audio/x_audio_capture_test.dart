import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/audio.dart';

Uint8List _bytes(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const methods = MethodChannel('ux/audio_capture');
  const events = MethodChannel('ux/audio_capture/events');

  group('XAudioFrame', () {
    test('decodes little-endian Int16 samples', () {
      final frame = XAudioFrame.fromBytes(_bytes([0, 1, -1, 32767, -32768]));
      expect(frame.samples, [0, 1, -1, 32767, -32768]);
    });

    test('decodes from a view that does not start at zero', () {
      final backing = _bytes([9999, 0, 7, -7]);
      final view = Uint8List.view(backing.buffer, 2, 6);
      expect(XAudioFrame.fromBytes(view).samples, [0, 7, -7]);
    });

    test('silence is level 0', () {
      expect(XAudioFrame(Int16List.fromList([0, 0, 0, 0])).level, 0);
    });

    test('an empty frame is level 0', () {
      expect(XAudioFrame(Int16List(0)).level, 0);
    });

    test('a full-scale square wave is level 1', () {
      final frame = XAudioFrame(Int16List.fromList([-32768, -32768, -32768]));
      expect(frame.level, closeTo(1.0, 1e-9));
    });

    test('a half-scale square wave is level 0.5', () {
      final frame = XAudioFrame(Int16List.fromList([16384, -16384, 16384]));
      expect(frame.level, closeTo(0.5, 1e-9));
    });

    test('level is the RMS, not the peak', () {
      // Half the samples at full scale, half silent → sqrt(1/2).
      final frame = XAudioFrame(Int16List.fromList([-32768, 0]));
      expect(frame.level, closeTo(0.7071067, 1e-6));
    });
  });

  group('MethodChannelXAudioCapture', () {
    final calls = <String>[];
    final arguments = <String, Object?>{};

    setUp(() {
      calls.clear();
      arguments.clear();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        arguments[call.method] = call.arguments;
        return null;
      });
      messenger.setMockMethodCallHandler(events, (call) async {
        calls.add('events.${call.method}');
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
      debugDefaultTargetPlatformOverride = null;
    });

    Future<void> sendEvent(Object? event) => messenger.handlePlatformMessage(
      'ux/audio_capture/events',
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );

    test('a frame event reaches the stream with its level', () async {
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();
      final received = <XAudioFrame>[];
      capture.frames.listen(received.add);

      await sendEvent({
        'type': 'frame',
        'pcm': _bytes([16384, -16384]),
      });
      await pumpEventQueue();

      expect(received, hasLength(1));
      expect(received.single.samples, [16384, -16384]);
      expect(received.single.level, closeTo(0.5, 1e-9));
    });

    test('state events drive the state listenable', () async {
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();
      expect(capture.state.value, XAudioCaptureState.idle);

      await sendEvent({'type': 'state', 'state': 'running'});
      await pumpEventQueue();
      expect(capture.state.value, XAudioCaptureState.running);

      await sendEvent({
        'type': 'state',
        'state': 'interrupted',
        'reason': 'routeChange',
      });
      await pumpEventQueue();
      expect(capture.state.value, XAudioCaptureState.interrupted);
    });

    test('an unknown state leaves the current one alone', () async {
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();
      await sendEvent({'type': 'state', 'state': 'running'});
      await pumpEventQueue();

      await sendEvent({'type': 'state', 'state': 'zzz'});
      await pumpEventQueue();
      expect(capture.state.value, XAudioCaptureState.running);
    });

    test('start and stop invoke the method channel', () async {
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();
      await capture.start();
      await capture.stop();
      expect(calls, containsAllInOrder(['start', 'stop']));
    });

    test('start without a source carries no arguments', () async {
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await capture.start();

      expect(arguments['start'], isNull);
    });

    test('start with a source carries its id', () async {
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await capture.start(sourceId: 'mic:7');

      expect(arguments['start'], {'sourceId': 'mic:7'});
    });

    test('start with voice processing off sends the flag', () async {
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await capture.start(voiceProcessing: false);

      expect(arguments['start'], {'voiceProcessing': false});
    });

    test('start with a source and voice processing off sends both', () async {
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await capture.start(sourceId: 'mic:7', voiceProcessing: false);

      expect(arguments['start'], {
        'sourceId': 'mic:7',
        'voiceProcessing': false,
      });
    });

    test('an unknown source fails with its code', () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        throw PlatformException(code: 'unknown_source', message: 'mic:99');
      });
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await expectLater(
        capture.start(sourceId: 'mic:99'),
        throwsA(
          isA<XAudioCaptureException>()
              .having((e) => e.code, 'code', 'unknown_source')
              .having((e) => e.message, 'message', 'mic:99'),
        ),
      );
    });

    test('sources decodes the platform list in order', () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        return const [
          {'id': 'mic:1', 'label': 'Built-in microphone', 'kind': 'microphone'},
          {'id': 'playback', 'label': 'Device playback', 'kind': 'playback'},
        ];
      });
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      expect(await capture.sources(), [
        const XAudioSource(
          id: 'mic:1',
          label: 'Built-in microphone',
          kind: XAudioSourceKind.microphone,
        ),
        const XAudioSource(
          id: 'playback',
          label: 'Device playback',
          kind: XAudioSourceKind.playback,
        ),
      ]);
      expect(calls, contains('sources'));
    });

    test('a source with an unknown kind is an invalid response', () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        return const [
          {'id': 'mic:1', 'label': 'Built-in', 'kind': 'telepathy'},
        ];
      });
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await expectLater(
        capture.sources(),
        throwsA(
          isA<XAudioCaptureException>().having(
            (e) => e.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });

    test('a source missing a field is an invalid response', () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        return const [
          {'id': 'mic:1', 'kind': 'microphone'},
        ];
      });
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await expectLater(
        capture.sources(),
        throwsA(
          isA<XAudioCaptureException>().having(
            (e) => e.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });

    test('a platform failure on sources surfaces as an exception', () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        throw PlatformException(code: 'unsupported', message: 'no tap');
      });
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await expectLater(
        capture.sources(),
        throwsA(
          isA<XAudioCaptureException>().having(
            (e) => e.code,
            'code',
            'unsupported',
          ),
        ),
      );
    });

    test('concurrent starts reach the platform one at a time', () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var starts = 0;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        if (call.method != 'start') return null;
        starts++;
        if (starts == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        }
        return null;
      });
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      final first = capture.start();
      await firstStarted.future;
      final second = capture.start();
      await pumpEventQueue();
      expect(starts, 1);

      releaseFirst.complete();
      await Future.wait([first, second]);
      expect(starts, 2);
    });

    test('stop waits for an in-flight start', () async {
      final startReachedPlatform = Completer<void>();
      final releaseStart = Completer<void>();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        if (call.method == 'start') {
          startReachedPlatform.complete();
          await releaseStart.future;
        }
        return null;
      });
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      final start = capture.start();
      await startReachedPlatform.future;
      final stop = capture.stop();
      await pumpEventQueue();
      expect(calls.where((call) => call == 'stop'), isEmpty);

      releaseStart.complete();
      await Future.wait([start, stop]);
      expect(calls, containsAllInOrder(['start', 'stop']));
    });

    test('a failed command does not prevent the next command', () async {
      var starts = 0;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        if (call.method == 'start' && starts++ == 0) {
          throw PlatformException(code: 'start_failed');
        }
        return null;
      });
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await expectLater(
        capture.start(),
        throwsA(isA<XAudioCaptureException>()),
      );
      await capture.start();

      expect(starts, 2);
    });

    test('a platform failure surfaces as XAudioCaptureException', () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        throw PlatformException(
          code: 'permission_denied',
          message: 'microphone',
        );
      });
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      await expectLater(
        capture.start(),
        throwsA(
          isA<XAudioCaptureException>()
              .having((e) => e.code, 'code', 'permission_denied')
              .having((e) => e.message, 'message', 'microphone'),
        ),
      );
    });

    test('an unsupported platform never touches the channels', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final capture = MethodChannelXAudioCapture();
      await pumpEventQueue();

      expect(calls, isEmpty);
      await expectLater(
        capture.start(),
        throwsA(
          isA<XAudioCaptureException>().having(
            (e) => e.code,
            'code',
            'unsupported',
          ),
        ),
      );
      await capture.stop();
      expect(calls, isEmpty);
      expect(await capture.sources(), isEmpty);
      expect(calls, isEmpty);
    });
  });
}
