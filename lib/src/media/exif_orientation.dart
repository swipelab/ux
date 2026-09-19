import 'dart:typed_data';

const int _soi = 0xFFD8;
const int _app1 = 0xFFE1;
const int _orientationTag = 0x0112;

/// Reads the EXIF Orientation tag (TIFF 0x0112) from a JPEG byte buffer.
/// Returns 1..8 per the TIFF/EXIF convention, or 1 if not present.
int readJpegExifOrientation(Uint8List bytes) {
  return _walkJpeg<int>(bytes, onApp1: _readFromApp1, onSof: null) ?? 1;
}

/// Raw stored pixel dimensions from a JPEG's SOFn marker (pre-EXIF).
({int width, int height})? readJpegRawDimensions(Uint8List bytes) {
  return _walkJpeg<({int width, int height})>(
    bytes,
    onApp1: null,
    onSof: _readSof,
  );
}

typedef _SegmentReader<T> = T? Function(Uint8List bytes, int start, int end);

T? _walkJpeg<T>(
  Uint8List bytes, {
  required _SegmentReader<T>? onApp1,
  required _SegmentReader<T>? onSof,
}) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 4 || data.getUint16(0) != _soi) return null;

  int cur = 2;
  while (cur + 4 <= bytes.length) {
    final marker = data.getUint16(cur);
    cur += 2;
    if ((marker & 0xFF00) != 0xFF00) return null;

    // Standalone markers (no length): SOI, EOI, TEM, RSTn.
    if (marker == 0xFFD8 || marker == 0xFFD9 || marker == 0xFF01) continue;
    if (marker >= 0xFFD0 && marker <= 0xFFD7) continue;

    // Start of scan — past here is compressed data, no more APP segments.
    if (marker == 0xFFDA) return null;

    if (cur + 2 > bytes.length) return null;
    final segLen = data.getUint16(cur);
    if (segLen < 2 || cur + segLen > bytes.length) return null;

    final payloadStart = cur + 2;
    final payloadEnd = cur + segLen;

    if (onApp1 != null && marker == _app1) {
      final v = onApp1(bytes, payloadStart, payloadEnd);
      if (v != null) return v;
    }
    // SOFn markers carry raw frame dimensions. Skip differential-encoding
    // (DHT, DAC) markers (0xFFC4, 0xFFCC) and SOI-family (0xFFC8 reserved).
    if (onSof != null &&
        marker >= 0xFFC0 && marker <= 0xFFCF &&
        marker != 0xFFC4 && marker != 0xFFC8 && marker != 0xFFCC) {
      final v = onSof(bytes, payloadStart, payloadEnd);
      if (v != null) return v;
    }
    cur += segLen;
  }
  return null;
}

/// Return a copy of the JPEG with every APP1 (EXIF) segment removed. On
/// non-JPEG or malformed input, returns the original bytes unchanged.
Uint8List stripJpegApp1(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return bytes;
  final data = ByteData.sublistView(bytes);
  final b = BytesBuilder(copy: false);
  b.add([0xFF, 0xD8]);
  int cur = 2;
  while (cur + 2 <= bytes.length) {
    final marker = data.getUint16(cur);
    if ((marker & 0xFF00) != 0xFF00) return bytes;

    // Standalone markers (no length): SOI, EOI, TEM, RSTn — copy as-is.
    if (marker == 0xFFD8 || marker == 0xFFD9 || marker == 0xFF01 ||
        (marker >= 0xFFD0 && marker <= 0xFFD7)) {
      b.add([0xFF, marker & 0xFF]);
      cur += 2;
      continue;
    }

    // Start of scan — copy the rest (entropy-coded data) verbatim and stop.
    if (marker == 0xFFDA) {
      b.add(Uint8List.sublistView(bytes, cur));
      return b.toBytes();
    }

    if (cur + 4 > bytes.length) return bytes;
    final segLen = data.getUint16(cur + 2);
    if (segLen < 2 || cur + 2 + segLen > bytes.length) return bytes;

    if (marker == _app1) {
      cur += 2 + segLen;
    } else {
      b.add(Uint8List.sublistView(bytes, cur, cur + 2 + segLen));
      cur += 2 + segLen;
    }
  }
  return b.toBytes();
}

({int width, int height})? _readSof(Uint8List bytes, int start, int end) {
  // SOFn payload: precision(1) + height(2 BE) + width(2 BE) + ...
  if (end - start < 5) return null;
  final data = ByteData.sublistView(bytes, start, end);
  final h = data.getUint16(1);
  final w = data.getUint16(3);
  if (w <= 0 || h <= 0) return null;
  return (width: w, height: h);
}

int? _readFromApp1(Uint8List bytes, int start, int end) {
  // APP1 payload begins with "Exif\0\0" then a TIFF block.
  if (end - start < 14) return null;
  if (bytes[start] != 0x45 || // 'E'
      bytes[start + 1] != 0x78 || // 'x'
      bytes[start + 2] != 0x69 || // 'i'
      bytes[start + 3] != 0x66 || // 'f'
      bytes[start + 4] != 0x00 ||
      bytes[start + 5] != 0x00) {
    return null;
  }

  final tiffStart = start + 6;
  final bom0 = bytes[tiffStart];
  final bom1 = bytes[tiffStart + 1];
  final Endian endian;
  if (bom0 == 0x49 && bom1 == 0x49) {
    endian = Endian.little;
  } else if (bom0 == 0x4D && bom1 == 0x4D) {
    endian = Endian.big;
  } else {
    return null;
  }

  final tiff = ByteData.sublistView(bytes, tiffStart, end);
  if (tiff.lengthInBytes < 8 || tiff.getUint16(2, endian) != 0x002A) return null;

  final ifd0Offset = tiff.getUint32(4, endian);
  if (ifd0Offset + 2 > tiff.lengthInBytes) return null;

  final entryCount = tiff.getUint16(ifd0Offset, endian);
  final entriesStart = ifd0Offset + 2;
  if (entriesStart + entryCount * 12 > tiff.lengthInBytes) return null;

  for (int i = 0; i < entryCount; ++i) {
    final e = entriesStart + i * 12;
    final tag = tiff.getUint16(e, endian);
    if (tag != _orientationTag) continue;
    final type = tiff.getUint16(e + 2, endian);
    if (type != 3) return null;
    final value = tiff.getUint16(e + 8, endian);
    if (value < 1 || value > 8) return null;
    return value;
  }
  return null;
}
