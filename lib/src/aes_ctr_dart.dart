import 'dart:typed_data';

import 'package:pointycastle/export.dart' hide Digest, State;

/// Pure-Dart AES-256-CTR — the software fallback for
/// [XCrypto.aesCtrEncryptRange] on platforms with no native hardware-AES
/// handler (web / linux / unit tests). Web-safe (no `dart:io`,
/// no `dart:isolate`): pointycastle is pure Dart.
///
/// The convention follows `proto/README.md`:
/// - 16-byte IV used as the **initial 128-bit counter block**.
/// - Counter increments big-endian by 1 per AES block.
/// - Per-chunk encryption advances the counter by `pos / 16` blocks AND
///   discards `pos % 16` bytes of in-block keystream so chunked encryption
///   produces the same ciphertext as streaming encryption regardless of how
///   the backend partitions the upload (some servers return parts whose
///   `pos`/`size` are not multiples of 16 — e.g. when capping the part count
///   and dividing `fileSize` evenly). This MUST stay byte-for-byte identical to
///   the native path ([XCrypto.aesCtrEncryptRange]); the cross-engine parity
///   tests are the guard.

/// Big-endian add of [n] into the bottom of [counter] with carry, mutating in
/// place.
void incCounter(Uint8List counter, int n) {
  for (var i = counter.length - 1; i >= 0 && n > 0; i--) {
    n += counter[i];
    counter[i] = n & 0xff;
    n >>= 8;
  }
}

/// Encrypts [plain] under AES-256-CTR with [key] and base counter block
/// [baseIv], producing the keystream bytes that a streaming cipher initialised
/// at offset 0 would produce at byte positions `[pos, pos + plain.length)`.
///
/// Counter is advanced by `pos / 16` blocks so the cipher is on the right AES
/// block. If `pos % 16 != 0`, the first `pos % 16` keystream bytes of that block
/// are discarded so the cipher's internal within-block state aligns with byte
/// position `pos`. Returns a fresh [Uint8List]; [baseIv] is not mutated.
Uint8List encryptChunk(
  Uint8List key,
  Uint8List baseIv,
  int pos,
  Uint8List plain,
) {
  final chunkIv = Uint8List.fromList(baseIv);
  incCounter(chunkIv, pos >> 4);
  final cipher = SICStreamCipher(AESEngine())
    ..init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), chunkIv));
  final byteOffset = pos & 15;
  if (byteOffset != 0) {
    // Consume `byteOffset` keystream bytes so the cipher is positioned at byte
    // `byteOffset` of block `pos / 16`, matching where a continuous streaming
    // cipher would be after processing `pos` bytes.
    final discardIn = Uint8List(byteOffset);
    final discardOut = Uint8List(byteOffset);
    cipher.processBytes(discardIn, 0, byteOffset, discardOut, 0);
  }
  final out = Uint8List(plain.length);
  cipher.processBytes(plain, 0, plain.length, out, 0);
  return out;
}
