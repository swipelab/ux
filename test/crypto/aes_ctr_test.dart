import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/crypto.dart';
// White-box: the software fallback is not part of the public API, but the
// parity contract (it must match encryptChunk byte-for-byte, and the native
// path) is exactly what these tests guard.
import 'package:ux/src/crypto_range_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows encrypts a range through ux/crypto aesCtrRange', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('ux/crypto');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    final cipher = Uint8List.fromList([1, 2, 3]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return cipher;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final key = Uint8List(32);
    final iv = Uint8List(16);

    final result = await XCrypto.aesCtrEncryptRange(
      path: r'C:\in\a.bin',
      pos: 17,
      size: 3,
      key: key,
      iv: iv,
    );

    expect(result, cipher);
    expect(calls.single.method, 'aesCtrRange');
    expect(calls.single.arguments, {
      'path': r'C:\in\a.bin',
      'pos': 17,
      'size': 3,
      'key': key,
      'iv': iv,
    });
  });

  group('encryptChunk counter math (chunked == streaming)', () {
    test('aligned chunks (1 MiB partSize) round-trip', () {
      _roundTrip(plainSize: 4 * 1024 * 1024 + 123, partSize: 1024 * 1024);
    });

    test('non-16-aligned chunks (BE-imposed odd partSize) round-trip', () {
      // The BE returns parts whose pos/size are not multiples of 16 (it caps
      // the part count and divides fileSize evenly). The keystream-misalignment
      // bug reproduces at any non-16-aligned partSize.
      _roundTrip(plainSize: 1000000, partSize: 60001);
      _roundTrip(plainSize: 1000000, partSize: 7);
    });

    test('many tiny non-aligned chunks (every pos % 16 residue)', () {
      _roundTrip(plainSize: 65, partSize: 3);
    });

    test('pos=0 encrypts plain exactly as streaming does', () {
      _roundTrip(plainSize: 1024, partSize: 1024);
    });
  });

  group(
    'encryptRangeFallback (dart:io read + isolate) parity with encryptChunk',
    () {
      late io.Directory dir;
      setUp(() => dir = io.Directory.systemTemp.createTempSync('ux_aes_ctr_'));
      tearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      test(
        'byte-identical to encryptChunk across aligned and non-16-aligned pos',
        () async {
          final key = Uint8List.fromList(
            List<int>.generate(32, (i) => i * 3 + 1),
          );
          final iv = Uint8List.fromList(
            List<int>.generate(16, (i) => 0xC0 + i),
          );
          final plain = Uint8List(40003);
          for (var i = 0; i < plain.length; i++) {
            plain[i] = (i * 17 + 5) & 0xFF;
          }
          final f = io.File('${dir.path}/src.bin')..writeAsBytesSync(plain);
          // Spans every pos % 16 residue plus a large offset.
          for (final pos in [0, 1, 15, 16, 17, 4096, 40000]) {
            final size = plain.length - pos;
            final reference = encryptChunk(
              key,
              iv,
              pos,
              Uint8List.sublistView(plain, pos),
            );
            final viaFallback = await encryptRangeFallback(
              f.path,
              pos,
              size,
              key,
              iv,
            );
            expect(
              viaFallback,
              equals(reference),
              reason: 'range fallback diverged from the primitive at pos=$pos',
            );
          }
        },
      );

      test('empty range', () async {
        final f = io.File('${dir.path}/empty.bin')
          ..writeAsBytesSync(Uint8List(0));
        final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
        final iv = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
        expect(
          await encryptRangeFallback(f.path, 0, 0, key, iv),
          equals(encryptChunk(key, iv, 0, Uint8List(0))),
        );
      });

      test('short read fails loud (StateError) — a truncated source never PUTs '
          'a too-short ciphertext', () async {
        final f = io.File('${dir.path}/short.bin')
          ..writeAsBytesSync(Uint8List(10));
        await expectLater(
          encryptRangeFallback(f.path, 0, 20, Uint8List(32), Uint8List(16)),
          throwsA(isA<StateError>()),
        );
      });
    },
  );
}

/// Chunked-encrypt [plain] at [partSize] via [encryptChunk], concatenate, then
/// stream-decrypt (encryptChunk at pos=0 over the full ciphertext — AES-CTR is
/// self-inverse) and assert the result equals [plain]. This is the
/// upload-chunking-vs-download-streaming contract.
void _roundTrip({required int plainSize, required int partSize}) {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final iv = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
  final plain = Uint8List(plainSize);
  for (var i = 0; i < plainSize; i++) {
    plain[i] = (i * 31 + 7) & 0xFF;
  }

  final ciphertext = Uint8List(plainSize);
  var pos = 0;
  while (pos < plainSize) {
    final size = (pos + partSize > plainSize) ? plainSize - pos : partSize;
    final chunkPlain = Uint8List.sublistView(plain, pos, pos + size);
    ciphertext.setRange(
      pos,
      pos + size,
      encryptChunk(key, iv, pos, chunkPlain),
    );
    pos += size;
  }

  final decrypted = encryptChunk(key, iv, 0, ciphertext);
  expect(
    decrypted,
    equals(plain),
    reason:
        'keystream desync at chunk boundaries '
        '(partSize=$partSize, plainSize=$plainSize)',
  );
}
