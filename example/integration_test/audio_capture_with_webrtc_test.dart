import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ux/ux.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('frames continue while flutter_webrtc holds the microphone',
      (tester) async {
    final mediaStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    final capture = XAudioCapture.instance;
    final frames = <XAudioFrame>[];
    final receivedFrames = Completer<void>();
    final subscription = capture.frames.listen((frame) {
      frames.add(frame);
      if (frames.length == 5 && !receivedFrames.isCompleted) {
        receivedFrames.complete();
      }
    });
    addTearDown(() async {
      await capture.stop();
      await subscription.cancel();
      for (final track in mediaStream.getTracks()) {
        track.stop();
      }
      await mediaStream.dispose();
    });

    expect(mediaStream.getAudioTracks(), hasLength(1));
    await capture.start();
    await receivedFrames.future.timeout(const Duration(seconds: 10));

    expect(capture.state.value, XAudioCaptureState.running);
    expect(frames, hasLength(greaterThanOrEqualTo(5)));
    for (final frame in frames) {
      expect(frame.samples, hasLength(XAudioCapture.frameSamples));
      expect(frame.level, inInclusiveRange(0.0, 1.0));
    }
  });
}
