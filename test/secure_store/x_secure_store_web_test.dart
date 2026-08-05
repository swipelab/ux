@TestOn('browser')
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/secure_store/x_secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a browser has no secure store', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final store = MethodChannelXSecureStore();

    expect(store.supported, isFalse);
    await expectLater(
      store.write('session', 'token-1'),
      throwsA(
        isA<XSecureStoreException>()
            .having((error) => error.code, 'code', 'unsupported'),
      ),
    );
  });
}
