import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/screen/x_screen_sources.dart';
import 'package:ux/src/screen/x_screen_sources_channel.dart';

const _channel = MethodChannel('ux/screen_sources');

Matcher get _unsupported => throwsA(
      isA<XScreenSourcesException>()
          .having((e) => e.code, 'code', 'unsupported'),
    );

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('${TargetPlatform.macOS}', () {
    late MethodChannelXScreenSourcesBackend backend;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      backend = MethodChannelXScreenSourcesBackend();
    });

    test('is supported and picker-driven', () {
      expect(backend.supported, isTrue);
      expect(backend.captureMode, XScreenCaptureMode.pickerDriven);
    });

    test('the share bracket is unsupported and touches no channel', () async {
      await expectLater(
        backend.startShare(notificationTitle: 'Sharing your screen'),
        _unsupported,
      );
      await expectLater(backend.stopShare(), _unsupported);
      expect(calls, isEmpty);
    });
  });

  for (final platform in const [TargetPlatform.android, TargetPlatform.iOS]) {
    group('$platform', () {
      late MethodChannelXScreenSourcesBackend backend;

      setUp(() {
        debugDefaultTargetPlatformOverride = platform;
        backend = MethodChannelXScreenSourcesBackend();
      });

      test('is supported and consent-driven', () {
        expect(backend.supported, isTrue);
        expect(backend.captureMode, XScreenCaptureMode.consentDriven);
        expect(calls, isEmpty);
      });

      test('the picker calls are unsupported and touch no channel', () async {
        await expectLater(backend.hasPermission(), _unsupported);
        await expectLater(backend.requestPermission(), _unsupported);
        await expectLater(
          backend.list(allowedDisplayIds: const {}, allowedWindowIds: const {}),
          _unsupported,
        );
        expect(calls, isEmpty);
      });

      test('the share bracket reaches the channel', () async {
        await backend.startShare(notificationTitle: 'Sharing your screen');
        await backend.stopShare();

        expect(calls.map((c) => c.method), ['startShare', 'stopShare']);
      });
    });
  }

  for (final (platform, mode) in const <(TargetPlatform, XScreenCaptureMode?)>[
    (TargetPlatform.linux, null),
    (TargetPlatform.windows, null),
    (TargetPlatform.fuchsia, null),
  ]) {
    group('$platform', () {
      late MethodChannelXScreenSourcesBackend backend;

      setUp(() {
        debugDefaultTargetPlatformOverride = platform;
        backend = MethodChannelXScreenSourcesBackend();
      });

      test('is not supported', () {
        expect(backend.supported, isFalse);
      });

      test('reports $mode without touching the channel', () {
        expect(backend.captureMode, mode);
        expect(calls, isEmpty);
      });

      test('every method throws unsupported and touches no channel', () async {
        await expectLater(backend.available(), _unsupported);
        await expectLater(backend.hasPermission(), _unsupported);
        await expectLater(backend.requestPermission(), _unsupported);
        await expectLater(
          backend.list(allowedDisplayIds: const {}, allowedWindowIds: const {}),
          _unsupported,
        );
        await expectLater(
          backend.startShare(notificationTitle: 'Sharing your screen'),
          _unsupported,
        );
        await expectLater(backend.stopShare(), _unsupported);
        expect(calls, isEmpty);
      });

      test('unsupported wins over out-of-bounds dimensions', () async {
        await expectLater(
          backend.list(
            allowedDisplayIds: const {},
            allowedWindowIds: const {},
            thumbnailWidth: 0,
            thumbnailHeight: 99999,
          ),
          _unsupported,
        );
        expect(calls, isEmpty);
      });

      test('unsupported wins over an empty notification title', () async {
        await expectLater(
          backend.startShare(notificationTitle: ''),
          _unsupported,
        );
        expect(calls, isEmpty);
      });
    });
  }
}
