import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

const _channelName = 'ux/screen_sources';
const _channel = MethodChannel(_channelName);

const _listArgumentKeys = {
  'allowedDisplayIds',
  'allowedWindowIds',
  'thumbnailWidth',
  'thumbnailHeight',
};

Map<String, Object?> _display() => {
      'id': 'display:1',
      'kind': 'display',
      'title': 'Built-in Retina Display',
      'applicationName': null,
      'sourceWidth': 3024,
      'sourceHeight': 1964,
      'thumbnailPng': null,
    };

Map<String, Object?> _window() => {
      'id': 'window:42',
      'kind': 'window',
      'title': 'Inbox — 3 unread',
      'applicationName': 'Mail',
      'sourceWidth': 1280,
      'sourceHeight': 800,
      'thumbnailPng': Uint8List.fromList([137, 80, 78, 71]),
    };

Matcher _invalidResponse(String field) => throwsA(
      isA<XScreenSourcesException>()
          .having((e) => e.code, 'code', 'invalid_response')
          .having((e) => e.message, 'message', startsWith('$field:')),
    );

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  late MethodChannelXScreenSourcesBackend backend;
  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall call)? handler;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    backend = MethodChannelXScreenSourcesBackend();
    calls = [];
    handler = null;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return handler?.call(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<List<XScreenSource>> list({
    Set<String> displays = const {'display:1'},
    Set<String> windows = const {'window:42'},
    int width = 320,
    int height = 180,
  }) =>
      backend.list(
        allowedDisplayIds: displays,
        allowedWindowIds: windows,
        thumbnailWidth: width,
        thumbnailHeight: height,
      );

  group('decode', () {
    test('round-trips a display and a window', () async {
      handler = (_) async => [_display(), _window()];

      final sources = await list();

      expect(sources, hasLength(2));
      expect(sources[0].id, 'display:1');
      expect(sources[0].kind, XScreenSourceKind.display);
      expect(sources[0].title, 'Built-in Retina Display');
      expect(sources[0].applicationName, isNull);
      expect(sources[0].sourceWidth, 3024);
      expect(sources[0].sourceHeight, 1964);
      expect(sources[1].id, 'window:42');
      expect(sources[1].kind, XScreenSourceKind.window);
      expect(sources[1].title, 'Inbox — 3 unread');
      expect(sources[1].applicationName, 'Mail');
      expect(sources[1].sourceWidth, 1280);
      expect(sources[1].sourceHeight, 800);
      expect(sources[1].thumbnailPng, [137, 80, 78, 71]);
    });

    test('a null thumbnail stays null', () async {
      handler = (_) async => [_display()];

      expect((await list()).single.thumbnailPng, isNull);
    });

    test('an empty snapshot decodes to an empty list', () async {
      handler = (_) async => <Object?>[];

      expect(await list(), isEmpty);
    });
  });

  group('strict decode', () {
    const wrongTypes = <String, Object?>{
      'id': 7,
      'kind': 'monitor',
      'title': false,
      'applicationName': 12,
      'sourceWidth': '3024',
      'sourceHeight': 1964.5,
      'thumbnailPng': 'png-bytes',
    };

    for (final entry in wrongTypes.entries) {
      test('${entry.key} of the wrong type names the field', () async {
        handler = (_) async => [_window()..[entry.key] = entry.value];

        await expectLater(list(), _invalidResponse(entry.key));
      });

      test('a missing ${entry.key} names the field', () async {
        handler = (_) async => [_window()..remove(entry.key)];

        await expectLater(list(), _invalidResponse(entry.key));
      });
    }

    test('an unknown key names it', () async {
      handler = (_) async => [_window()..['displayScale'] = 2];

      await expectLater(list(), _invalidResponse('displayScale'));
    });

    test('a source that is not a map is rejected', () async {
      handler = (_) async => ['display:1'];

      await expectLater(list(), _invalidResponse('source'));
    });

    test('a reply that is not a list is rejected', () async {
      handler = (_) async => _window();

      await expectLater(list(), _invalidResponse('result'));
    });

    test('a permission reply that is not a bool is rejected', () async {
      handler = (_) async => 'yes';

      await expectLater(backend.hasPermission(), _invalidResponse('result'));
    });
  });

  group('dimension bounds', () {
    for (final (width, height) in const [
      (0, 180),
      (-1, 180),
      (4097, 180),
      (320, 0),
      (320, -1),
      (320, 4097),
    ]) {
      test('${width}x$height throws before the channel', () async {
        await expectLater(
          list(width: width, height: height),
          throwsArgumentError,
        );
        expect(calls, isEmpty);
      });
    }

    test('1x1 and 4096x4096 reach the channel', () async {
      handler = (_) async => <Object?>[];

      await list(width: 1, height: 1);
      await list(width: 4096, height: 4096);

      expect(calls, hasLength(2));
    });
  });

  group('exception mapping', () {
    for (final code in const [
      'unsupported',
      'permission_denied',
      'enumeration_failed',
      'thumbnail_failed',
      'something_native_invented',
    ]) {
      test('$code passes through code-for-code', () async {
        handler =
            (_) async => throw PlatformException(code: code, message: 'detail');

        await expectLater(
          list(),
          throwsA(
            isA<XScreenSourcesException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.message, 'message', 'detail'),
          ),
        );
      });
    }

    test('a permission failure maps the same way', () async {
      handler = (_) async => throw PlatformException(code: 'permission_denied');

      await expectLater(
        backend.requestPermission(),
        throwsA(
          isA<XScreenSourcesException>()
              .having((e) => e.code, 'code', 'permission_denied'),
        ),
      );
    });
  });

  group('request wire', () {
    test('calls arrive on $_channelName', () async {
      handler = (_) async => <Object?>[];

      await list();

      expect(calls, hasLength(1));
    });

    test('the bool methods carry their name and no arguments', () async {
      handler = (_) async => true;

      await backend.available();
      await backend.hasPermission();
      await backend.requestPermission();

      expect(
        calls.map((c) => c.method),
        ['available', 'hasPermission', 'requestPermission'],
      );
      expect(calls.every((c) => c.arguments == null), isTrue);
    });

    test('list carries exactly the contracted argument map', () async {
      handler = (_) async => <Object?>[];

      await list(
        displays: {'display:1', 'display:2'},
        windows: {'window:42'},
        width: 640,
        height: 360,
      );

      final call = calls.single;
      expect(call.method, 'list');
      final args = (call.arguments as Map).cast<Object?, Object?>();
      expect(args.keys.toSet(), _listArgumentKeys);
      final displays = args['allowedDisplayIds']! as List<Object?>;
      final windows = args['allowedWindowIds']! as List<Object?>;
      expect(displays, everyElement(isA<String>()));
      expect(displays, unorderedEquals(['display:1', 'display:2']));
      expect(windows, everyElement(isA<String>()));
      expect(windows, ['window:42']);
      expect(args['thumbnailWidth'], isA<int>());
      expect(args['thumbnailWidth'], 640);
      expect(args['thumbnailHeight'], isA<int>());
      expect(args['thumbnailHeight'], 360);
    });

    test('empty allow-sets are sent as empty lists', () async {
      handler = (_) async => <Object?>[];

      await list(displays: const {}, windows: const {});

      final args = (calls.single.arguments as Map).cast<Object?, Object?>();
      expect(args['allowedDisplayIds'], isEmpty);
      expect(args['allowedWindowIds'], isEmpty);
    });

    test('the default thumbnail size is 320x180', () async {
      handler = (_) async => <Object?>[];

      await backend.list(
        allowedDisplayIds: const {},
        allowedWindowIds: const {},
      );

      final args = (calls.single.arguments as Map).cast<Object?, Object?>();
      expect(args['thumbnailWidth'], 320);
      expect(args['thumbnailHeight'], 180);
    });
  });

  group('share bracket', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      backend = MethodChannelXScreenSourcesBackend();
    });

    Map<Object?, Object?> argumentsOf(MethodCall call) =>
        (call.arguments as Map).cast<Object?, Object?>();

    test('available carries its name and no arguments', () async {
      handler = (_) async => true;

      expect(await backend.available(), isTrue);
      expect(calls.single.method, 'available');
      expect(calls.single.arguments, isNull);
    });

    test('start carries the notification and stop carries nothing', () async {
      await backend.startShare(
        notificationTitle: 'Sharing your screen',
        notificationText: 'Tap to return',
      );
      await backend.stopShare();

      expect(calls.map((c) => c.method), ['startShare', 'stopShare']);
      final args = argumentsOf(calls.first);
      expect(args.keys.toSet(), {'notificationTitle', 'notificationText'});
      expect(args['notificationTitle'], 'Sharing your screen');
      expect(args['notificationText'], 'Tap to return');
      expect(calls.last.arguments, isNull);
    });

    test('an omitted text is sent as null', () async {
      await backend.startShare(notificationTitle: 'Sharing your screen');

      expect(argumentsOf(calls.single)['notificationText'], isNull);
    });

    test('an empty title throws before the channel', () async {
      await expectLater(
        backend.startShare(notificationTitle: ''),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    });

    for (final code in const [
      'permission_denied',
      'service_start_failed',
      'unsupported',
    ]) {
      test('a start refused with $code passes it through', () async {
        handler =
            (_) async => throw PlatformException(code: code, message: 'detail');

        await expectLater(
          backend.startShare(notificationTitle: 'Sharing your screen'),
          throwsA(
            isA<XScreenSourcesException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.message, 'message', 'detail'),
          ),
        );
      });
    }

    test('a stop failure surfaces the same way', () async {
      handler =
          (_) async => throw PlatformException(code: 'service_start_failed');

      await expectLater(
        backend.stopShare(),
        throwsA(
          isA<XScreenSourcesException>()
              .having((e) => e.code, 'code', 'service_start_failed'),
        ),
      );
    });
  });
}
