import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XFiles.saveCopy — method channel parsing', () {
    const channel = MethodChannel('ux/file');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('encodes args and parses saved', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'saveCopy');
        final args = call.arguments as Map;
        expect(args['path'], '/tmp/report.pdf');
        expect(args['mimeType'], 'application/pdf');
        return 'saved';
      });

      final status = await XFiles.saveCopy(
        path: '/tmp/report.pdf',
        mimeType: 'application/pdf',
      );
      expect(status, XFileSaveStatus.saved);
    });

    test('omits mimeType when unset and parses denied', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        expect(args.containsKey('mimeType'), isFalse);
        return 'denied';
      });

      final status = await XFiles.saveCopy(path: '/tmp/x.bin');
      expect(status, XFileSaveStatus.denied);
    });

    test('anything else parses as cancelled', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => 'cancelled');

      final status = await XFiles.saveCopy(path: '/tmp/x.bin');
      expect(status, XFileSaveStatus.cancelled);
    });
  });
}
