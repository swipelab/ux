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

  test('macOS is supported', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    expect(MethodChannelXScreenSourcesBackend().supported, isTrue);
  });

  for (final platform in const [
    TargetPlatform.iOS,
    TargetPlatform.android,
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.fuchsia,
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

      test('every method throws unsupported and touches no channel', () async {
        await expectLater(backend.available(), _unsupported);
        await expectLater(backend.hasPermission(), _unsupported);
        await expectLater(backend.requestPermission(), _unsupported);
        await expectLater(
          backend.list(allowedDisplayIds: const {}, allowedWindowIds: const {}),
          _unsupported,
        );
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
    });
  }
}
