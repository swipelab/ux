import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// The software fallback reads the file (dart:io) and runs the cipher on an
// isolate; behind a conditional import so `crypto.dart` stays web-compilable
// (web gets the stub, which throws — web has no native handler and no file-path
// upload, so it never reaches the fallback).
import 'crypto_range_stub.dart'
    if (dart.library.io) 'crypto_range_io.dart' as range_fallback;

// Re-export the pure-Dart primitive so consumers (and the cross-engine parity
// tests) get the whole AES-CTR contract — hardware-or-fallback — from one place.
export 'aes_ctr_dart.dart' show encryptChunk;

/// AES-256-CTR backed by the platform's hardware-accelerated crypto — Android
/// `javax.crypto` (Conscrypt/BoringSSL → ARMv8 AES instructions), Apple
/// CommonCrypto — with a transparent pure-Dart fallback ([encryptChunk]) where
/// no native handler ships (web / linux / windows / unit tests). The bytes are
/// encrypted as if a single continuous CTR stream whose initial counter block
/// is [iv] had already processed [pos] plaintext bytes; CTR is symmetric, so the
/// same call also decrypts. Native and fallback are byte-for-byte identical —
/// the cross-engine parity tests are the guard.
///
/// The point is to keep a large attachment's encryption (100MB+ video) off the
/// UI isolate *and* fast: hardware AES runs on a native background thread, the
/// fallback on a spawned isolate, and the Dart caller only awaits a [Future].
class XCrypto {
  XCrypto._();

  static const _channel = MethodChannel('ux/crypto');

  /// Whether a native handler ships on this platform. Web-safe (uses
  /// [defaultTargetPlatform], never `dart:io`) and cheap — it does not touch
  /// the channel. Note this returns true under `flutter test` on a macOS/iOS
  /// host even though no plugin is registered there, so a call throws
  /// [MissingPluginException] — callers must treat that as a fallback signal,
  /// the same as any native error.
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
  /// offsets); the counter is advanced by `pos >> 4` blocks and `pos & 15`
  /// keystream bytes discarded so the slice stays aligned with a continuous
  /// stream from offset 0.
  ///
  /// Never returns null: when native hardware AES is unavailable or fails, it
  /// falls back to reading the range and encrypting on a background isolate
  /// ([range_fallback.encryptRangeFallback] → [encryptChunk]). The fallback
  /// guards a short read (a truncated source fails loud, like the native side).
  static Future<Uint8List> aesCtrEncryptRange({
    required String path,
    required int pos,
    required int size,
    required Uint8List key,
    required Uint8List iv,
  }) async {
    assert(key.length == 32, 'AES-256 key must be 32 bytes, got ${key.length}');
    assert(iv.length == 16, 'CTR IV must be 16 bytes, got ${iv.length}');
    assert(pos >= 0 && size >= 0, 'pos/size must be non-negative');
    if (isSupported) {
      try {
        final native = await _channel
            .invokeMethod<Uint8List>('aesCtrRange', <String, Object?>{
          'path': path,
          'pos': pos,
          'size': size,
          'key': key,
          'iv': iv,
        });
        if (native != null) return native;
      } catch (e) {
        // A native error (PlatformException) or a host with no registered
        // plugin (MissingPluginException under flutter test) — both fall back
        // to the Dart path. Log it: a fallback on a device that SHOULD have
        // hardware AES is the anomaly worth seeing.
        debugPrint('ux/crypto: native aesCtrRange unavailable ($e); Dart fallback');
      }
    }
    return range_fallback.encryptRangeFallback(path, pos, size, key, iv);
  }

  /// Bytes-in / bytes-out variant of [aesCtrEncryptRange] — encrypts [data]
  /// directly instead of reading from disk. Used by the cross-engine parity
  /// test; production uploads use the range form so the plaintext stays off
  /// the Dart heap.
  static Future<Uint8List?> aesCtrBytes({
    required Uint8List key,
    required Uint8List iv,
    required int pos,
    required Uint8List data,
  }) {
    assert(key.length == 32, 'AES-256 key must be 32 bytes, got ${key.length}');
    assert(iv.length == 16, 'CTR IV must be 16 bytes, got ${iv.length}');
    assert(pos >= 0, 'pos must be non-negative');
    if (!isSupported) return Future.value(null);
    return _channel.invokeMethod<Uint8List>('aesCtrBytes', <String, Object?>{
      'key': key,
      'iv': iv,
      'pos': pos,
      'data': data,
    });
  }
}
