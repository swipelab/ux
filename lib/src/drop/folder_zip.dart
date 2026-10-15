import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Zips [folder] in an isolate into `<system temp>/ux_drops/<uuid>/<name>.zip`,
/// where `<name>` is the folder's name and the archive's root, deflated, with
/// zip64 records where the archive passes 4 GiB or 65,535 entries.
///
/// [onProgress] receives the fraction of the folder's bytes read, and 1 once
/// the zip is written. Completes with the zip's path, or null when [cancel]
/// completes first; throws when the zip fails. A cancelled or failed zip
/// leaves no per-drop directory behind.
Future<String?> zipFolder(
  String folder, {
  required void Function(double fraction) onProgress,
  required Future<void> cancel,
}) async {
  final dir = p.join(Directory.systemTemp.path, 'ux_drops', _uuid());
  final zip = p.join(dir, '${p.basename(folder)}.zip');
  final messages = ReceivePort();
  final control = Completer<SendPort>();
  var cancelled = false;
  messages.listen((message) {
    if (message is SendPort) {
      control.complete(message);
    } else if (message is double) {
      onProgress(message);
    }
  });
  unawaited(
    cancel.then((_) async {
      cancelled = true;
      (await control.future).send(null);
    }),
  );
  try {
    await _spawn(folder, zip, messages.sendPort);
    if (!cancelled) {
      onProgress(1);
      return zip;
    }
  } catch (_) {
    if (!cancelled) {
      await _remove(dir);
      rethrow;
    }
  } finally {
    messages.close();
  }
  await _remove(dir);
  return null;
}

/// Runs [_writeZip] in an isolate. The closure lives here, so its context
/// holds only what the isolate can receive.
Future<void> _spawn(String folder, String zip, SendPort reports) =>
    Isolate.run(() => _writeZip(folder, zip, reports));

Future<void> _remove(String dir) async {
  final directory = Directory(dir);
  if (await directory.exists()) await directory.delete(recursive: true);
}

/// A random version 4 UUID, in upper case.
String _uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = bytes[6] & 0x0f | 0x40;
  bytes[8] = bytes[8] & 0x3f | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return [
    hex.substring(0, 8),
    hex.substring(8, 12),
    hex.substring(12, 16),
    hex.substring(16, 20),
    hex.substring(20),
  ].join('-').toUpperCase();
}

class _Cancelled implements Exception {
  const _Cancelled();
}

const _max32 = 0xFFFFFFFF;
const _max16 = 0xFFFF;
const _chunk = 1 << 20;

/// A folder or file of the zip, by its name in the archive.
class _Source {
  _Source(this.name, this.path, this.size, this.modified);

  /// The archive name: the folder's name, then the path below it with `/`
  /// separators, ending in `/` for a folder.
  final String name;
  final String path;

  /// The file's length, or null for a folder.
  final int? size;
  final DateTime modified;
}

/// An entry written into the zip, as the central directory records it.
class _Entry {
  _Entry(this.name, this.offset, this.modified, {required this.isDirectory});

  final List<int> name;
  final int offset;
  final DateTime modified;
  final bool isDirectory;
  int crc = 0;
  int compressed = 0;
  int size = 0;
}

/// Runs in the zip's isolate: sends [reports] a SendPort whose message cancels
/// the zip, then the fraction of bytes read as it goes.
Future<void> _writeZip(String folder, String zip, SendPort reports) async {
  final control = ReceivePort();
  var cancelled = false;
  control.listen((_) => cancelled = true);
  reports.send(control.sendPort);
  RandomAccessFile? out;
  try {
    final sources = await _sources(folder);
    final total = sources.fold<int>(0, (sum, s) => sum + (s.size ?? 0));
    await Directory(p.dirname(zip)).create(recursive: true);
    out = await File(zip).open(mode: FileMode.write);
    final entries = <_Entry>[];
    var read = 0;
    var reported = -1;
    for (final source in sources) {
      if (cancelled) throw const _Cancelled();
      final entry = _Entry(
        utf8.encode(source.name),
        await out.position(),
        source.modified,
        isDirectory: source.size == null,
      );
      entries.add(entry);
      final size = source.size;
      if (size == null) {
        await out.writeFrom(_localHeader(entry, zip64: false));
        continue;
      }
      final zip64 = _deflateBound(size) >= _max32;
      await out.writeFrom(_localHeader(entry, zip64: zip64));
      final input = await File(source.path).open();
      try {
        final deflated = <List<int>>[];
        final deflater = ZLibEncoder(raw: true)
            .startChunkedConversion(_Collect(deflated));
        Future<void> flush() async {
          for (final bytes in deflated) {
            entry.compressed += bytes.length;
            await out!.writeFrom(bytes);
          }
          deflated.clear();
        }

        while (true) {
          final bytes = await input.read(_chunk);
          if (bytes.isEmpty) break;
          if (cancelled) throw const _Cancelled();
          entry.crc = _crc32(entry.crc, bytes);
          entry.size += bytes.length;
          deflater.add(bytes);
          await flush();
          read += bytes.length;
          final step = total == 0 ? 200 : min(200, read * 200 ~/ total);
          if (step > reported) {
            reported = step;
            reports.send(step / 200);
          }
        }
        deflater.close();
        await flush();
      } finally {
        await input.close();
      }
      if (!zip64 && (entry.size >= _max32 || entry.compressed >= _max32)) {
        throw FileSystemException('grew past 4 GiB while zipped', source.path);
      }
      final end = await out.position();
      await out.setPosition(entry.offset + 14);
      await out.writeFrom(_crcAndSizes(entry, zip64: zip64));
      if (zip64) {
        await out.setPosition(entry.offset + 34 + entry.name.length);
        await out.writeFrom(_wideSizes(entry));
      }
      await out.setPosition(end);
    }
    final directory = await out.position();
    final central = BytesBuilder(copy: false);
    for (final entry in entries) {
      central.add(_centralHeader(entry));
    }
    await out.writeFrom(central.takeBytes());
    await out.writeFrom(
      _end(entries.length, directory, await out.position() - directory),
    );
  } finally {
    await out?.close();
    control.close();
  }
}

/// The folder and everything under it, links followed, each folder before
/// what it holds. A link that leads nowhere holds nothing to zip.
Future<List<_Source>> _sources(String folder) async {
  final root = p.basename(folder);
  final sources = [
    _Source('$root/', folder, null, (await Directory(folder).stat()).modified),
  ];
  final found = <_Source>[];
  await for (final entity in Directory(
    folder,
  ).list(recursive: true, followLinks: true)) {
    if (entity is Link) continue;
    final below = p.split(p.relative(entity.path, from: folder)).join('/');
    final stat = await entity.stat();
    found.add(
      entity is Directory
          ? _Source('$root/$below/', entity.path, null, stat.modified)
          : _Source('$root/$below', entity.path, stat.size, stat.modified),
    );
  }
  found.sort((a, b) => a.name.compareTo(b.name));
  return sources..addAll(found);
}

/// zlib's bound on the deflated length of [size] bytes.
int _deflateBound(int size) =>
    size + (size >> 12) + (size >> 14) + (size >> 25) + 13;

const _utf8Names = 0x0800;
const _version = 20;
const _version64 = 45;

Uint8List _localHeader(_Entry entry, {required bool zip64}) {
  final header = ByteData(30 + entry.name.length + (zip64 ? 20 : 0))
    ..setUint32(0, 0x04034b50, Endian.little)
    ..setUint16(4, zip64 ? _version64 : _version, Endian.little)
    ..setUint16(6, _utf8Names, Endian.little)
    ..setUint16(8, entry.isDirectory ? 0 : 8, Endian.little)
    ..setUint16(10, _dosTime(entry.modified), Endian.little)
    ..setUint16(12, _dosDate(entry.modified), Endian.little)
    ..setUint16(26, entry.name.length, Endian.little)
    ..setUint16(28, zip64 ? 20 : 0, Endian.little);
  final bytes = header.buffer.asUint8List()..setAll(30, entry.name);
  if (zip64) {
    header
      ..setUint16(30 + entry.name.length, 0x0001, Endian.little)
      ..setUint16(32 + entry.name.length, 16, Endian.little);
  }
  return bytes;
}

/// The CRC and sizes of a written entry, as its local header holds them from
/// its offset 14: the sizes are in its zip64 field when it has one.
Uint8List _crcAndSizes(_Entry entry, {required bool zip64}) =>
    (ByteData(12)
          ..setUint32(0, entry.crc, Endian.little)
          ..setUint32(4, zip64 ? _max32 : entry.compressed, Endian.little)
          ..setUint32(8, zip64 ? _max32 : entry.size, Endian.little))
        .buffer
        .asUint8List();

/// The sizes of a written entry, as its local header's zip64 field holds them.
Uint8List _wideSizes(_Entry entry) =>
    (ByteData(16)
          ..setUint64(0, entry.size, Endian.little)
          ..setUint64(8, entry.compressed, Endian.little))
        .buffer
        .asUint8List();

Uint8List _centralHeader(_Entry entry) {
  final wide = [
    if (entry.size >= _max32) entry.size,
    if (entry.compressed >= _max32) entry.compressed,
    if (entry.offset >= _max32) entry.offset,
  ];
  final extra = wide.isEmpty ? 0 : 4 + 8 * wide.length;
  final version = wide.isEmpty ? _version : _version64;
  final header = ByteData(46 + entry.name.length + extra)
    ..setUint32(0, 0x02014b50, Endian.little)
    ..setUint16(4, version, Endian.little)
    ..setUint16(6, version, Endian.little)
    ..setUint16(8, _utf8Names, Endian.little)
    ..setUint16(10, entry.isDirectory ? 0 : 8, Endian.little)
    ..setUint16(12, _dosTime(entry.modified), Endian.little)
    ..setUint16(14, _dosDate(entry.modified), Endian.little)
    ..setUint32(16, entry.crc, Endian.little)
    ..setUint32(20, min(entry.compressed, _max32), Endian.little)
    ..setUint32(24, min(entry.size, _max32), Endian.little)
    ..setUint16(28, entry.name.length, Endian.little)
    ..setUint16(30, extra, Endian.little)
    ..setUint32(38, entry.isDirectory ? 0x10 : 0, Endian.little)
    ..setUint32(42, min(entry.offset, _max32), Endian.little);
  final bytes = header.buffer.asUint8List()..setAll(46, entry.name);
  if (wide.isNotEmpty) {
    final at = 46 + entry.name.length;
    header
      ..setUint16(at, 0x0001, Endian.little)
      ..setUint16(at + 2, 8 * wide.length, Endian.little);
    for (var i = 0; i < wide.length; i++) {
      header.setUint64(at + 4 + 8 * i, wide[i], Endian.little);
    }
  }
  return bytes;
}

/// The end of central directory record, after the zip64 record and its
/// locator when the counts or offsets pass the 16- and 32-bit fields.
Uint8List _end(int count, int offset, int size) {
  final zip64 = count >= _max16 || offset >= _max32 || size >= _max32;
  final end = ByteData((zip64 ? 76 : 0) + 22);
  var at = 0;
  if (zip64) {
    final record = offset + size;
    end
      ..setUint32(0, 0x06064b50, Endian.little)
      ..setUint64(4, 44, Endian.little)
      ..setUint16(12, _version64, Endian.little)
      ..setUint16(14, _version64, Endian.little)
      ..setUint64(24, count, Endian.little)
      ..setUint64(32, count, Endian.little)
      ..setUint64(40, size, Endian.little)
      ..setUint64(48, offset, Endian.little)
      ..setUint32(56, 0x07064b50, Endian.little)
      ..setUint64(64, record, Endian.little)
      ..setUint32(72, 1, Endian.little);
    at = 76;
  }
  end
    ..setUint32(at, 0x06054b50, Endian.little)
    ..setUint16(at + 8, min(count, _max16), Endian.little)
    ..setUint16(at + 10, min(count, _max16), Endian.little)
    ..setUint32(at + 12, min(size, _max32), Endian.little)
    ..setUint32(at + 16, min(offset, _max32), Endian.little);
  return end.buffer.asUint8List();
}

/// [time] as an MS-DOS time, in two-second steps.
int _dosTime(DateTime time) => time.year < 1980
    ? 0
    : time.hour << 11 | time.minute << 5 | time.second ~/ 2;

/// [time] as an MS-DOS date, which starts in 1980.
int _dosDate(DateTime time) => time.year < 1980
    ? 1 << 5 | 1
    : (time.year - 1980) << 9 | time.month << 5 | time.day;

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// [crc], the CRC-32 of the bytes before [bytes], extended over them.
int _crc32(int crc, List<int> bytes) {
  var c = crc ^ _max32;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ _max32;
}

class _Collect implements Sink<List<int>> {
  _Collect(this.chunks);

  final List<List<int>> chunks;

  @override
  void add(List<int> data) => chunks.add(data);

  @override
  void close() {}
}
