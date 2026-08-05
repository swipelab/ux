import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ux/ux.dart';
import 'package:ux_example/audio_sink_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 20 ms at XAudioSink.sampleRate.
  const chunkSamples = 320;
  const chunk = Duration(milliseconds: 20);

  // The native side reports state over the event channel, which settles
  // behind the command that caused it.
  Future<void> expectState(XAudioSink sink, XAudioSinkState want) async {
    for (var i = 0; sink.state.value != want && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(sink.state.value, want);
  }

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

  testWidgets('the sink plays a stream while capture and flutter_webrtc run',
      (tester) async {
    const chunks = 50;
    final mediaStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    final capture = XAudioCapture.instance;
    final sink = XAudioSink.instance;
    final frames = <XAudioFrame>[];
    final captureSubscription = capture.frames.listen(frames.add);
    var drains = 0;
    final firstDrain = Completer<void>();
    final sinkSubscription = sink.drained.listen((_) {
      drains++;
      if (!firstDrain.isCompleted) firstDrain.complete();
    });
    addTearDown(() async {
      await sink.flush();
      await capture.stop();
      await sinkSubscription.cancel();
      await captureSubscription.cancel();
      for (final track in mediaStream.getTracks()) {
        track.stop();
      }
      await mediaStream.dispose();
    });

    await capture.start();
    final elapsed = Stopwatch()..start();
    // A socket delivers faster than real time: hand over a lead of audio,
    // then keep feeding slightly ahead of the rate it plays.
    for (var i = 0; i < 20; i++) {
      await sink.enqueue(toneChunk(i * chunkSamples, chunkSamples));
    }
    await expectState(sink, XAudioSinkState.playing);
    final framesWhileFeeding = frames.length;

    for (var i = 20; i < chunks; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await sink.enqueue(toneChunk(i * chunkSamples, chunkSamples));
    }
    await firstDrain.future.timeout(const Duration(seconds: 10));
    elapsed.stop();

    // The queue holds one second of audio. Draining earlier means chunks were
    // dropped at a seam, later means playback stalled between them.
    expect(elapsed.elapsed, greaterThan(chunk * chunks * 0.9));
    expect(elapsed.elapsed, lessThan(chunk * chunks * 2.5));
    expect(drains, 1);
    await expectState(sink, XAudioSinkState.idle);

    // The microphone kept delivering throughout the playback.
    expect(capture.state.value, XAudioCaptureState.running);
    expect(frames.length, greaterThan(framesWhileFeeding));
    expect(mediaStream.getAudioTracks(), hasLength(1));
  });

  testWidgets('flush drops the queue and the next stream starts clean',
      (tester) async {
    final sink = XAudioSink.instance;
    var drains = 0;
    final subscription = sink.drained.listen((_) => drains++);
    addTearDown(() async {
      await sink.flush();
      await subscription.cancel();
    });

    // Five seconds of audio, handed over as fast as it can be enqueued.
    for (var i = 0; i < 250; i++) {
      await sink.enqueue(toneChunk(i * chunkSamples, chunkSamples));
    }
    await expectState(sink, XAudioSinkState.playing);

    await sink.flush();
    await expectState(sink, XAudioSinkState.idle);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(drains, 0);

    final drained = Completer<void>();
    final second = sink.drained.listen((_) {
      if (!drained.isCompleted) drained.complete();
    });
    addTearDown(second.cancel);
    for (var i = 0; i < 10; i++) {
      await sink.enqueue(toneChunk(i * chunkSamples, chunkSamples));
    }
    await drained.future.timeout(const Duration(seconds: 5));
    await expectState(sink, XAudioSinkState.idle);
  });
}
