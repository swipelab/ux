import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';
import 'package:ux_example/audio_sink_page.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const methods = MethodChannel('ux/audio_sink');
  const events = MethodChannel('ux/audio_sink/events');

  final sink = XAudioSink.instance;

  final calls = <MethodCall>[];

  Future<void> sendEvent(Object? event) => messenger.handlePlatformMessage(
        'ux/audio_sink/events',
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );

  setUp(() async {
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async => null);
    // XAudioSink.instance is process-wide: hand each test an idle sink.
    await sendEvent({'type': 'state', 'state': 'idle'});
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  List<String> methodNames() => [for (final call in calls) call.method];

  test('the tone keeps its phase across chunk boundaries', () {
    final whole = toneChunk(0, 640);
    final second = toneChunk(320, 320);
    expect(second, whole.sublist(320));
  });

  test('the tone is a 440 Hz sine', () {
    final chunk = toneChunk(0, XAudioSink.sampleRate);
    // A full second holds 440 rising zero crossings.
    var crossings = 0;
    for (var i = 1; i < chunk.length; i++) {
      if (chunk[i - 1] < 0 && chunk[i] >= 0) crossings++;
    }
    expect(crossings, closeTo(440, 1));
    expect(chunk.reduce(math.max), closeTo(12000, 2));
  });

  testWidgets('streaming feeds the sink chunk by chunk', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AudioSinkPage()));
    expect(find.text('state: idle'), findsOneWidget);

    await tester.tap(find.text('Stream tone'));
    await tester.pump();
    expect(methodNames(), ['enqueue']);

    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(methodNames(), ['enqueue', 'enqueue']);

    final first = calls.first.arguments as Uint8List;
    expect(first, hasLength(640));

    await sendEvent({'type': 'state', 'state': 'playing'});
    await tester.pump();
    expect(sink.state.value, XAudioSinkState.playing);
    expect(find.text('state: playing'), findsOneWidget);

    await tester.tap(find.text('Flush'));
    await tester.pumpAndSettle();
    expect(methodNames().last, 'flush');
  });

  testWidgets('a drain event counts on the page', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AudioSinkPage()));
    expect(find.textContaining('0 drained'), findsOneWidget);

    await sendEvent({'type': 'drained'});
    await tester.pump();

    expect(find.textContaining('1 drained'), findsOneWidget);
  });

  testWidgets('a refused output surfaces the platform code', (tester) async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(
        code: 'no_output_device',
        message: '16 kHz mono PCM16 unavailable',
      );
    });
    await tester.pumpWidget(const MaterialApp(home: AudioSinkPage()));

    await tester.tap(find.text('Stream tone'));
    await tester.pumpAndSettle();

    expect(
      find.text('no_output_device: 16 kHz mono PCM16 unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('disposing the page always flushes the sink', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AudioSinkPage()));
    calls.clear();

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(methodNames(), contains('flush'));
  });
}
