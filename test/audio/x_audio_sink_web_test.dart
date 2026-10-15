@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/audio/x_audio_sink.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audio playback is unsupported in a browser', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final sink = MethodChannelXAudioSink();

    expect(sink.supported, isFalse);
    await expectLater(
      sink.enqueue(Int16List.fromList([1, 2])),
      throwsA(
        isA<XAudioSinkException>().having(
          (error) => error.code,
          'code',
          'unsupported',
        ),
      ),
    );
    await sink.flush();
  });
}
