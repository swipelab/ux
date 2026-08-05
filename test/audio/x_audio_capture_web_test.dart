@TestOn('browser')
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/audio/x_audio_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audio capture is unsupported in a browser', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final capture = MethodChannelXAudioCapture();

    expect(capture.supported, isFalse);
    await expectLater(
      capture.start(),
      throwsA(
        isA<XAudioCaptureException>()
            .having((error) => error.code, 'code', 'unsupported'),
      ),
    );
    await capture.stop();
  });
}
