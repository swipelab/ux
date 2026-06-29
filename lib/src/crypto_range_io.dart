import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import 'aes_ctr_dart.dart';

/// Software fallback for [XCrypto.aesCtrEncryptRange] where no native handler
/// ships. Opens [path], reads `[pos, pos+size)` (guarding a short read exactly
/// like the native `readRange`, so a truncated/shrunken source fails loud
/// instead of producing a too-short ciphertext), then AES-256-CTR-encrypts the
/// slice on a background isolate — the heavy Dart cipher must never block the
/// caller's UI isolate (a 100MB+ attachment would freeze the app).
///
/// Lives behind a conditional import so the web build (which has no `dart:io`
/// and never reaches this path) compiles against [crypto_range_stub] instead.
Future<Uint8List> encryptRangeFallback(
  String path,
  int pos,
  int size,
  Uint8List key,
  Uint8List iv,
) async {
  final raf = await io.File(path).open();
  Uint8List plain;
  try {
    await raf.setPosition(pos);
    plain = await raf.read(size);
  } finally {
    await raf.close();
  }
  if (plain.length != size) {
    throw StateError('short read: ${plain.length} of $size at $pos ($path)');
  }
  return Isolate.run(() => encryptChunk(key, iv, pos, plain));
}
