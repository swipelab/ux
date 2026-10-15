import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ux/crypto.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // NIST SP 800-38A, F.5.5 CTR-AES256.Encrypt.
  final key = _hex(
    '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4',
  );
  final initialCounter = _hex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
  final plaintext = _hex(
    '6bc1bee22e409f96e93d7e117393172a'
    'ae2d8a571e03ac9c9eb76fac45af8e51'
    '30c81c46a35ce411e5fbc1191a0a52ef'
    'f69f2445df4f9b17ad2b417be66c3710',
  );
  final ciphertext = _hex(
    '601ec313775789a5b7a7f504bbf3d228'
    'f443e3ca4d62b59aca84e990cacaf5c5'
    '2b0930daa23de94ce87017ba2d84988d'
    'dfc9c58db67aada613c2dd08457941a6',
  );

  testWidgets(
    'the NIST SP 800-38A vectors encrypt from the start and from inside a '
    'block',
    (tester) async {
      expect(
        await XCrypto.aesCtrBytes(
          key: key,
          iv: initialCounter,
          pos: 0,
          data: plaintext,
        ),
        ciphertext,
      );
      expect(
        await XCrypto.aesCtrBytes(
          key: key,
          iv: initialCounter,
          pos: 21,
          data: plaintext.sublist(21, 51),
        ),
        ciphertext.sublist(21, 51),
      );
    },
  );

  testWidgets(
    'the counter carries from its low 64 bits into its high 64 bits, as '
    'encryptChunk carries it',
    (tester) async {
      // From inside a block, with the low 64 bits wrapping 625 blocks in.
      final iv = _hex('0101010101010101ffffffffffffec78');
      final data = Uint8List.fromList(
        List<int>.generate(200003, (i) => (i * 31 + 7) & 0xff),
      );

      expect(
        await XCrypto.aesCtrBytes(key: key, iv: iv, pos: 70001, data: data),
        encryptChunk(key, iv, 70001, data),
      );
    },
  );
}

Uint8List _hex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);
