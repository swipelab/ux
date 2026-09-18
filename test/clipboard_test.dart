import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XClipboard — method channel parsing', () {
    const channel = MethodChannel('ux/clipboard');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('readFiles decodes path/name/bookmark entries', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'readFiles');
        return [
          {
            'path': '/Users/x/pic.png',
            'name': 'pic.png',
            'bookmark': Uint8List.fromList([1, 2, 3]),
          },
          {'path': '/Users/x/doc.pdf', 'name': 'doc.pdf'},
        ];
      });

      final files = await XClipboard.readFiles();
      expect(files, hasLength(2));
      expect(files[0].path, '/Users/x/pic.png');
      expect(files[0].name, 'pic.png');
      expect(files[0].bookmark, [1, 2, 3]);
      expect(files[1].bookmark, isNull);
    });

    test('readFiles resolves to empty on unimplemented platforms', () async {
      // No mock handler installed → MissingPluginException path.
      expect(await XClipboard.readFiles(), isEmpty);
    });

    test('hasMedia forwards the platform bool and defaults false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'hasMedia');
        return true;
      });
      expect(await XClipboard.hasMedia(), isTrue);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      // MissingPluginException path (no handler) → false.
      expect(await XClipboard.hasMedia(), isFalse);
    });

    test('readImage returns bytes verbatim and null on failure', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'readImage');
        return Uint8List.fromList([9, 9]);
      });
      expect(await XClipboard.readImage(), [9, 9]);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'boom');
      });
      expect(await XClipboard.readImage(), isNull);
    });
  });
}
