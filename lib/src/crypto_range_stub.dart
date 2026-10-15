import 'dart:typed_data';

/// Web stub for [encryptRangeFallback] — selected by the conditional import in
/// `crypto.dart` when `dart:io` is unavailable. Web has no native hardware-AES
/// handler and no file-path upload, so this path is never reached in practice;
/// it throws loudly rather than silently mis-encrypting if it ever is.
Future<Uint8List> encryptRangeFallback(
  String path,
  int pos,
  int size,
  Uint8List key,
  Uint8List iv,
) => throw UnsupportedError(
  'aesCtrEncryptRange software fallback needs dart:io (unavailable on web)',
);
