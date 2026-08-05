import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux_example/audio_capture_page.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const methods = MethodChannel('ux/audio_capture');
  const events = MethodChannel('ux/audio_capture/events');

  final calls = <String>[];

  Future<void> sendEvent(Object? event) => messenger.handlePlatformMessage(
        'ux/audio_capture/events',
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );

  setUp(() async {
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async => null);
    // XAudioCapture.instance is process-wide: hand each test an idle tap.
    await sendEvent({'type': 'state', 'state': 'idle'});
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Uint8List pcm(List<int> samples) {
    final data = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(i * 2, samples[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  testWidgets('Start asks the tap to open, and the meter follows the frames',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AudioCapturePage()));
    expect(find.text('state: idle'), findsOneWidget);
    expect(find.text('level 0.000'), findsOneWidget);

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(calls, contains('start'));

    await sendEvent({'type': 'state', 'state': 'running'});
    await sendEvent({'type': 'frame', 'pcm': pcm([16384, -16384])});
    await tester.pumpAndSettle();

    expect(find.text('state: running'), findsOneWidget);
    expect(find.text('level 0.500'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    final bar = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(bar.widthFactor, 1.0);

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(calls, contains('stop'));
  });

  testWidgets('an interruption shows up in the state line', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AudioCapturePage()));
    await sendEvent({'type': 'state', 'state': 'running'});
    await tester.pumpAndSettle();

    await sendEvent({
      'type': 'state',
      'state': 'interrupted',
      'reason': 'configurationChange',
    });
    await tester.pumpAndSettle();

    expect(find.text('state: interrupted'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets('a refused tap surfaces the platform code', (tester) async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'permission_denied', message: 'microphone');
    });
    await tester.pumpWidget(const MaterialApp(home: AudioCapturePage()));

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(find.text('permission_denied: microphone'), findsOneWidget);
  });
}
