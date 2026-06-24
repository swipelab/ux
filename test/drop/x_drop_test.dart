import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

void main() {
  group('XDropFile.fromItem', () {
    test('parses isTemporaryCopy and isDirectory from the native item', () {
      final f = XDropFile.fromItem(<Object?, Object?>{
        'path': '/tmp/ux_drops/abc/foo.png',
        'name': 'foo.png',
        'isTemporaryCopy': true,
        'isDirectory': false,
      })!;
      expect(f.path, '/tmp/ux_drops/abc/foo.png');
      expect(f.name, 'foo.png');
      expect(f.isTemporaryCopy, isTrue);
      expect(f.isDirectory, isFalse);
    });

    test('a plain file URL is a durable (non-temporary) drop', () {
      final f = XDropFile.fromItem(<Object?, Object?>{
        'path': '/Users/me/Downloads/report.pdf',
        'name': 'report.pdf',
        'isTemporaryCopy': false,
      })!;
      expect(f.isTemporaryCopy, isFalse);
      expect(f.isDirectory, isFalse);
    });

    test('flags default to false when the native side omits them', () {
      final f = XDropFile.fromItem(<Object?, Object?>{'path': '/a/b.txt'})!;
      expect(f.isTemporaryCopy, isFalse);
      expect(f.isDirectory, isFalse);
      expect(f.name, 'b.txt'); // basename fallback when no name supplied
    });

    test('marks a dropped folder / package as a directory', () {
      final f = XDropFile.fromItem(<Object?, Object?>{
        'path': '/Users/me/VMs/Linux.utm',
        'name': 'Linux.utm',
        'isDirectory': true,
      })!;
      expect(f.isDirectory, isTrue);
    });

    test('carries the security-scoped bookmark bytes through', () {
      final bytes = Uint8List.fromList([0, 1, 2, 3]);
      final f = XDropFile.fromItem(<Object?, Object?>{
        'path': '/a/b',
        'bookmark': bytes,
      })!;
      expect(f.bookmark, bytes);
    });

    test('returns null for an item with no usable path', () {
      expect(XDropFile.fromItem(<Object?, Object?>{}), isNull);
      expect(XDropFile.fromItem(<Object?, Object?>{'path': ''}), isNull);
      expect(XDropFile.fromItem(<Object?, Object?>{'path': 42}), isNull);
    });
  });
}
