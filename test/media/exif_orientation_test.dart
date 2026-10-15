import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ux/media.dart';

/// Builds the minimum viable JPEG byte sequence that contains an EXIF APP1
/// segment with just the Orientation tag set. Structure:
///   SOI (FFD8)
///   APP1 (FFE1) + length + "Exif\0\0" + TIFF (II, 42, offset=8)
///     + IFD0: 1 entry: tag=0x0112, type=3 (SHORT), count=1, value=orient
///     + next-IFD offset (0)
///   EOI (FFD9)
Uint8List _jpegWithOrientation(
  int orientation, {
  Endian endian = Endian.little,
}) {
  final b = BytesBuilder();

  // SOI
  b.add([0xFF, 0xD8]);

  // APP1 header: FFE1 + 2-byte length (set after we know payload size)
  // Payload: "Exif\0\0" (6) + TIFF header (8) + IFD0 (2 + 12 + 4 = 18) = 32.
  // Length field includes its own 2 bytes → 34.
  b.add([0xFF, 0xE1, 0x00, 0x22]);

  // "Exif\0\0"
  b.add([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]);

  // TIFF header
  final tiff = BytesBuilder();
  if (endian == Endian.little) {
    tiff.add([0x49, 0x49]); // II
  } else {
    tiff.add([0x4D, 0x4D]); // MM
  }
  final tiffHeaderRest = ByteData(6);
  tiffHeaderRest.setUint16(0, 0x002A, endian); // 42
  tiffHeaderRest.setUint32(2, 8, endian); // IFD0 at offset 8
  tiff.add(tiffHeaderRest.buffer.asUint8List());

  // IFD0: 1 entry + 1 entry struct (12B) + next-IFD offset (4B)
  final ifd = ByteData(2 + 12 + 4);
  ifd.setUint16(0, 1, endian); // entry count
  // Entry: tag=0x0112, type=3, count=1, value=<orientation> in first 2 bytes.
  ifd.setUint16(2, 0x0112, endian); // tag
  ifd.setUint16(4, 3, endian); // type SHORT
  ifd.setUint32(6, 1, endian); // count
  ifd.setUint16(10, orientation, endian); // value (first 2 bytes of field)
  // bytes 12..13 are the remaining 2 bytes of the 4-byte valueOrOffset — leave zero.
  ifd.setUint32(14, 0, endian); // next IFD offset = 0

  tiff.add(ifd.buffer.asUint8List());
  b.add(tiff.toBytes());

  // EOI
  b.add([0xFF, 0xD9]);

  return b.toBytes();
}

void main() {
  group('readJpegExifOrientation', () {
    for (var o = 1; o <= 8; ++o) {
      test('little-endian (II) returns $o', () {
        final bytes = _jpegWithOrientation(o);
        expect(readJpegExifOrientation(bytes), o);
      });
      test('big-endian (MM) returns $o', () {
        final bytes = _jpegWithOrientation(o, endian: Endian.big);
        expect(readJpegExifOrientation(bytes), o);
      });
    }

    test('non-JPEG returns 1', () {
      expect(readJpegExifOrientation(Uint8List.fromList([0, 1, 2, 3])), 1);
    });

    test('empty returns 1', () {
      expect(readJpegExifOrientation(Uint8List(0)), 1);
    });

    test('JPEG without EXIF returns 1', () {
      final b = BytesBuilder();
      b.add([0xFF, 0xD8]); // SOI
      // JFIF APP0 (not APP1)
      b.add([0xFF, 0xE0, 0x00, 0x10]);
      b.add([0x4A, 0x46, 0x49, 0x46, 0x00]); // "JFIF\0"
      b.add(List.filled(12, 0));
      b.add([0xFF, 0xD9]); // EOI
      expect(readJpegExifOrientation(b.toBytes()), 1);
    });

    test('malformed APP1 segment length falls through safely', () {
      final b = BytesBuilder();
      b.add([0xFF, 0xD8]);
      // APP1 claims length 0xFFFF (overruns buffer) — must return 1, not crash.
      b.add([0xFF, 0xE1, 0xFF, 0xFF]);
      expect(readJpegExifOrientation(b.toBytes()), 1);
    });

    test('out-of-range orientation value returns 1', () {
      final bytes = _jpegWithOrientation(9);
      expect(readJpegExifOrientation(bytes), 1);
    });
  });

  group('readJpegRawDimensions', () {
    Uint8List jpegWithSof({required int width, required int height}) {
      final b = BytesBuilder();
      b.add([0xFF, 0xD8]); // SOI
      // SOF0 (FFC0): 8(precision) + 2(h) + 2(w) + 1(nf) = 8 bytes payload,
      // plus 2 bytes for the length field itself → length = 10.
      b.add([0xFF, 0xC0, 0x00, 0x0B]); // length = 11 (8 + 2 + 1 component byte)
      final payload = ByteData(9);
      payload.setUint8(0, 8); // precision
      payload.setUint16(1, height); // big-endian
      payload.setUint16(3, width);
      payload.setUint8(5, 1); // Nf
      payload.setUint8(6, 1); // component id
      payload.setUint8(7, 0x11); // sampling factors
      payload.setUint8(8, 0); // quant table
      b.add(payload.buffer.asUint8List());
      b.add([0xFF, 0xD9]); // EOI
      return b.toBytes();
    }

    test('reads landscape dims from SOF0', () {
      final bytes = jpegWithSof(width: 1920, height: 1080);
      final r = readJpegRawDimensions(bytes);
      expect(r, isNotNull);
      expect(r!.width, 1920);
      expect(r.height, 1080);
    });

    test('reads portrait dims from SOF0', () {
      final bytes = jpegWithSof(width: 1080, height: 1920);
      expect(readJpegRawDimensions(bytes), (width: 1080, height: 1920));
    });

    test('non-JPEG returns null', () {
      expect(readJpegRawDimensions(Uint8List.fromList([0, 1, 2, 3])), isNull);
    });

    test('JPEG without SOF returns null', () {
      final b = BytesBuilder();
      b.add([0xFF, 0xD8, 0xFF, 0xD9]); // SOI + EOI only
      expect(readJpegRawDimensions(b.toBytes()), isNull);
    });
  });

  group('stripJpegApp1', () {
    test('removes EXIF APP1 segment', () {
      final input = _jpegWithOrientation(6);
      final output = stripJpegApp1(input);
      expect(readJpegExifOrientation(output), 1);
      expect(output.length < input.length, true);
    });

    test('preserves non-APP1 segments', () {
      final b = BytesBuilder();
      b.add([0xFF, 0xD8]);
      b.add([0xFF, 0xE0, 0x00, 0x10]);
      b.add([0x4A, 0x46, 0x49, 0x46, 0x00]);
      b.add(List.filled(9, 0));
      final withExif = _jpegWithOrientation(3);
      final app1Start = 2;
      final app1Len = 0x22;
      b.add(withExif.sublist(app1Start, app1Start + 2 + app1Len));
      b.add([0xFF, 0xD9]);

      final input = b.toBytes();
      final output = stripJpegApp1(input);

      var foundApp0 = false;
      var foundApp1 = false;
      var cur = 2;
      while (cur + 2 <= output.length) {
        final m = (output[cur] << 8) | output[cur + 1];
        if (m == 0xFFE0) foundApp0 = true;
        if (m == 0xFFE1) foundApp1 = true;
        if (m == 0xFFD9) break;
        if (cur + 4 > output.length) break;
        final segLen = (output[cur + 2] << 8) | output[cur + 3];
        cur += 2 + segLen;
      }
      expect(foundApp0, true);
      expect(foundApp1, false);
    });

    test('non-JPEG returned unchanged', () {
      final bytes = Uint8List.fromList([0, 1, 2, 3]);
      expect(stripJpegApp1(bytes), bytes);
    });

    test('JPEG without EXIF returned without loss', () {
      final b = BytesBuilder();
      b.add([0xFF, 0xD8]);
      b.add([0xFF, 0xE0, 0x00, 0x06, 0x01, 0x02, 0x03, 0x04]);
      b.add([0xFF, 0xD9]);
      final input = b.toBytes();
      expect(stripJpegApp1(input), input);
    });

    test('truncated segment length returned unchanged (safe fallback)', () {
      final b = BytesBuilder();
      b.add([0xFF, 0xD8]);
      b.add([0xFF, 0xE1, 0xFF, 0xFF]);
      final input = b.toBytes();
      expect(stripJpegApp1(input), input);
    });
  });
}
