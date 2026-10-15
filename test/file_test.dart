import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ux/file');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('XFiles.saveCopy — method channel parsing', () {
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

  group('XFiles.pickMultiple', () {
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test(
      'decodes the picked files in the order the picker reports them',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickMultiple');
          expect(call.arguments, {
            'mimeTypes': ['image/*', 'video/*'],
          });
          return [
            {
              'path': r'C:\in\b.mov',
              'name': 'b.mov',
              'mimeType': 'video/quicktime',
              'size': 2048,
            },
            {
              'path': r'C:\in\a.png',
              'name': 'a.png',
              'mimeType': 'image/png',
              'size': 512,
            },
          ];
        });

        final picked = await XFiles.pickMultiple(
          mimeTypes: ['image/*', 'video/*'],
        );
        expect(
          [for (final f in picked) f.path],
          [r'C:\in\b.mov', r'C:\in\a.png'],
        );
        expect([for (final f in picked) f.name], ['b.mov', 'a.png']);
        expect(
          [for (final f in picked) f.mimeType],
          ['video/quicktime', 'image/png'],
        );
        expect([for (final f in picked) f.size], [2048, 512]);
        expect(
          picked.every((f) => f.bookmark == null && !f.isTemporaryCopy),
          isTrue,
        );
      },
    );

    test('answers no files when the picker is cancelled', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => []);

      expect(await XFiles.pickMultiple(), isEmpty);
    });
  });

  group('XFiles on Windows', () {
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('saves copies and shows files in their folder', () {
      expect(XFiles.supportsSaveCopy, isTrue);
      expect(XFiles.supportsShowInFolder, isTrue);
    });

    test(
      'showInFolder hands the path to ux/file and answers what it answers',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });

        expect(await XFiles.showInFolder(path: r'C:\U8\f1\a.txt'), isTrue);
        expect(calls.single.method, 'showInFolder');
        expect(calls.single.arguments, {'path': r'C:\U8\f1\a.txt'});
      },
    );
  }, skip: Platform.isWindows ? null : 'the Windows branch runs on Windows');
}
