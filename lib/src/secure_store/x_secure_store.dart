import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

/// Thrown by [XSecureStore] when the platform store refuses an operation.
///
/// [code] is `unsupported` off the platforms that have a native store, and
/// otherwise the platform's own failure code (`store_failed`, `bad_args`).
/// Neither the key nor the value is part of [message].
class XSecureStoreException implements Exception {
  /// Creates an exception with a wire [code] and an optional [message].
  const XSecureStoreException(this.code, [this.message]);

  /// Machine-readable failure kind.
  final String code;

  /// Platform-supplied detail, when there is one.
  final String? message;

  @override
  String toString() => 'XSecureStoreException($code, $message)';
}

/// String secrets — session tokens, refresh tokens — kept by key in the OS
/// credential store rather than in app storage.
///
/// Apple backs each key with a `kSecClassGenericPassword` Keychain item
/// scoped to the host's bundle identifier and never synchronised to iCloud;
/// Android encrypts the value with an AndroidKeyStore AES-GCM key and keeps
/// the ciphertext in a private preferences file.
///
/// ```dart
/// final store = XSecureStore.instance;
/// await store.write('session', token);
/// final session = await store.read('session');
/// ```
///
/// Commands run in call order, so a [read] issued after a [write] observes
/// it. Values are never logged, on either side of the channel.
abstract interface class XSecureStore {
  /// The process-wide store. One credential store, one instance.
  static final XSecureStore instance = MethodChannelXSecureStore();

  /// Whether this platform has a native store. Elsewhere every operation
  /// throws [XSecureStoreException] with code `unsupported`.
  bool get supported;

  /// The value stored under [key], or `null` when the key holds nothing.
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing any value already there.
  Future<void> write(String key, String value);

  /// Removes [key]. Removing a key that holds nothing succeeds.
  Future<void> delete(String key);
}

/// Production [XSecureStore]: `ux/secure_store` for commands.
class MethodChannelXSecureStore implements XSecureStore {
  /// Creates a store bound to the platform channel.
  MethodChannelXSecureStore();

  static const _methods = MethodChannel('ux/secure_store');

  Future<void>? _commandTail;

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  Future<String?> read(String key) =>
      _enqueue(() => _invoke<String>('read', {'key': key}));

  @override
  Future<void> write(String key, String value) =>
      _enqueue(() => _invoke<void>('write', {'key': key, 'value': value}));

  @override
  Future<void> delete(String key) =>
      _enqueue(() => _invoke<void>('delete', {'key': key}));

  Future<T?> _invoke<T>(String method, Map<String, String> arguments) async {
    if (!supported) {
      throw XSecureStoreException('unsupported', '$defaultTargetPlatform');
    }
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw XSecureStoreException(e.code, e.message);
    }
  }

  Future<T?> _enqueue<T>(Future<T?> Function() command) {
    final previous = _commandTail;
    final operation = previous == null
        ? command()
        : previous.then((_) => command());
    final tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _commandTail = tail;
    tail.whenComplete(() {
      if (identical(_commandTail, tail)) _commandTail = null;
    });
    return operation;
  }
}
