import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ux/drop.dart';

/// A zip entry as its central directory records it, with its data inflated.
typedef _Entry = ({String name, int crc, int size, Uint8List data});

/// The entries of [zip], read without zip64 records.
List<_Entry> _readZip(Uint8List zip) {
  final bytes = ByteData.sublistView(zip);
  var end = zip.length - 22;
  while (bytes.getUint32(end, Endian.little) != 0x06054b50) {
    end--;
  }
  final count = bytes.getUint16(end + 10, Endian.little);
  var at = bytes.getUint32(end + 16, Endian.little);
  final entries = <_Entry>[];
  for (var i = 0; i < count; i++) {
    expect(bytes.getUint32(at, Endian.little), 0x02014b50);
    final method = bytes.getUint16(at + 10, Endian.little);
    final crc = bytes.getUint32(at + 16, Endian.little);
    final compressed = bytes.getUint32(at + 20, Endian.little);
    final size = bytes.getUint32(at + 24, Endian.little);
    final nameLength = bytes.getUint16(at + 28, Endian.little);
    final extra = bytes.getUint16(at + 30, Endian.little);
    final comment = bytes.getUint16(at + 32, Endian.little);
    final local = bytes.getUint32(at + 42, Endian.little);
    final name = utf8.decode(zip.sublist(at + 46, at + 46 + nameLength));
    final start =
        local +
        30 +
        bytes.getUint16(local + 26, Endian.little) +
        bytes.getUint16(local + 28, Endian.little);
    final stored = zip.sublist(start, start + compressed);
    final data = method == 8
        ? Uint8List.fromList(ZLibDecoder(raw: true).convert(stored))
        : stored;
    entries.add((name: name, crc: crc, size: size, data: data));
    at += 46 + nameLength + extra + comment;
  }
  return entries;
}

/// The names of the per-drop directories under the system temp's ux_drops.
Set<String> _drops() {
  final drops = Directory(p.join(Directory.systemTemp.path, 'ux_drops'));
  if (!drops.existsSync()) return {};
  return {for (final dir in drops.listSync()) p.basename(dir.path)};
}

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

  testWidgets(
    'on Windows a drop region subscribes the drop events',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('ux/drop/events'),
        (call) async => calls.add(call.method),
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('ux/drop'),
        (call) async => calls.add(call.method),
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('ux/drop/events'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('ux/drop'),
          null,
        );
      });
      await tester.pumpWidget(
        XDropRegion(builder: (context, isOver) => const SizedBox()),
      );
      expect(calls, ['listen', 'setHasRegions']);
    },
  );

  group('XDrop.startZip on Windows', () {
    late Directory root;
    late Directory tree;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      root = Directory.systemTemp.createTempSync('ux_zip_');
      tree = Directory(p.join(root.path, 'tree'));
      final files = {
        'readme.txt': utf8.encode('The fixture tree.\n' * 40),
        'nested/deeper/data.bin': List<int>.generate(
          3 << 20,
          (i) => (i * 7919) >> 5 & 0xff,
        ),
        '资料/笔记.txt': utf8.encode('非 ASCII 名称\n'),
      };
      for (final MapEntry(:key, :value) in files.entries) {
        File(p.join(tree.path, key))
          ..createSync(recursive: true)
          ..writeAsBytesSync(value);
      }
      Directory(p.join(tree.path, 'empty')).createSync();
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      root.deleteSync(recursive: true);
    });

    ZipJob zip() => XDrop.instance.startZip(
      XDropFile(path: tree.path, name: 'tree', isDirectory: true),
    );

    test('writes the tree under its own per-drop directory, and the zip reads '
        'back and passes unzip -t', () async {
      final job = zip();
      final file = (await job.result)!;
      final dir = File(file.path).parent;
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(job.progress.value, 1);
      expect(file.name, 'tree.zip');
      expect(file.isTemporaryCopy, isTrue);
      expect(dir.parent.path, p.join(Directory.systemTemp.path, 'ux_drops'));
      expect(dir.listSync().map((e) => e.path), [file.path]);

      final entries = _readZip(File(file.path).readAsBytesSync());
      expect(entries.map((e) => e.name), [
        'tree/',
        'tree/empty/',
        'tree/nested/',
        'tree/nested/deeper/',
        'tree/nested/deeper/data.bin',
        'tree/readme.txt',
        'tree/资料/',
        'tree/资料/笔记.txt',
      ]);
      for (final entry in entries) {
        if (entry.name.endsWith('/')) {
          expect(entry.size, 0);
          continue;
        }
        final source = File(p.join(root.path, p.joinAll(entry.name.split('/'))))
            .readAsBytesSync();
        expect(entry.size, source.length, reason: entry.name);
        expect(entry.data, source, reason: entry.name);
      }

      final test = await Process.run('unzip', ['-t', file.path]);
      expect(test.exitCode, 0, reason: '${test.stdout}${test.stderr}');
      expect(test.stdout, contains('No errors detected'));
      final listing = await Process.run('unzip', ['-v', file.path]);
      final listed = RegExp(r'^\s*(\d+)\s.*\s([0-9a-f]{8})\s', multiLine: true)
          .allMatches(listing.stdout as String)
          .map((m) => (int.parse(m[1]!), int.parse(m[2]!, radix: 16)));
      expect(listed, [for (final e in entries) (e.size, e.crc)]);
    });

    test('a cancelled job answers null and leaves neither its zip nor its '
        'directory', () async {
      final random = Random(1);
      File(p.join(tree.path, 'noise.bin')).writeAsBytesSync(
        List<int>.generate(16 << 20, (_) => random.nextInt(256)),
      );
      final before = _drops();
      final job = zip();
      job.progress.addListener(() {
        if (job.progress.value > 0) job.cancel();
      });

      expect(await job.result, isNull);
      expect(_drops(), before);
    });

    test('a failed job throws and leaves no directory', () async {
      final unreadable = p.join(tree.path, 'readme.txt');
      // Windows ignores chmod's mode bits, but fails a read of a range that
      // another handle has locked.
      if (Platform.isWindows) {
        final holder = await File(unreadable).open(mode: FileMode.append);
        await holder.lock();
        addTearDown(holder.close);
      } else {
        expect((await Process.run('chmod', ['000', unreadable])).exitCode, 0);
        addTearDown(() => Process.runSync('chmod', ['644', unreadable]));
      }
      final before = _drops();

      await expectLater(zip().result, throwsA(isA<FileSystemException>()));
      expect(_drops(), before);
    });
  });
}
