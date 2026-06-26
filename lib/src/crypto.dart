import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// AES-256-CTR backed by the platform's hardware-accelerated crypto — Android
/// `javax.crypto` (Conscrypt/BoringSSL → ARMv8 AES instructions), Apple
/// CommonCrypto. It mirrors, byte-for-byte, the app's pure-Dart `encryptChunk`:
/// the bytes are encrypted as if a single continuous CTR stream whose initial
/// counter block is [iv] had already processed [pos] plaintext bytes. CTR is
/// symmetric, so the same call also decrypts.
///
/// The point is to keep a large attachment's encryption (100MB+ video) off the
/// UI isolate *and* fast: the heavy AES runs on a native background thread and
/// the Dart caller only awaits a [Future]. Where no native handler exists
/// (web / linux / windows / unit tests) the methods return null and callers
/// fall back to the Dart path.
class XCrypto {
  XCrypto._();

  static const _channel = MethodChannel('ux/crypto');

  /// Whether a native handler ships on this platform. Web-safe (uses
  /// [defaultTargetPlatform], never `dart:io`) and cheap — it does not touch
  /// the channel.
  static bool get isSupported {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return true;
      default:
        return false;
    }
  }

  /// Encrypts `file[pos .. pos+size)` and returns the ciphertext. The native
  /// side opens [path], seeks to [pos], reads [size] bytes, and encrypts them
  /// off the platform main thread — only the ciphertext crosses the channel,
  /// so a large attachment never copies its plaintext into the Dart heap.
  ///
  /// [key] must be 32 bytes (AES-256), [iv] 16 (the initial counter block).
  /// [pos] may be non-16-aligned (the backend partitions parts on arbitrary
  /// offsets); the native side advances the counter by `pos >> 4` blocks and
  /// discards `pos & 15` keystream bytes so the slice stays aligned with a
  /// continuous stream from offset 0. Returns null when [isSupported] is false;
  /// throws [PlatformException] on a native error (callers fall back to Dart).
  static Future<Uint8List?> aesCtrEncryptRange({
    required String path,
    required int pos,
    required int size,
    required Uint8List key,
    required Uint8List iv,
  }) {
    if (!isSupported) return Future.value(null);
    return _channel.invokeMethod<Uint8List>('aesCtrRange', <String, Object?>{
      'path': path,
      'pos': pos,
      'size': size,
      'key': key,
      'iv': iv,
    });
  }

  /// Bytes-in / bytes-out variant of [aesCtrEncryptRange] — encrypts [data]
  /// directly instead of reading from disk. Used by the cross-engine parity
  /// test and a startup self-check; production uploads use the range form so
  /// the plaintext stays off the Dart heap.
  static Future<Uint8List?> aesCtrBytes({
    required Uint8List key,
    required Uint8List iv,
    required int pos,
    required Uint8List data,
  }) {
    if (!isSupported) return Future.value(null);
    return _channel.invokeMethod<Uint8List>('aesCtrBytes', <String, Object?>{
      'key': key,
      'iv': iv,
      'pos': pos,
      'data': data,
    });
  }
}
