import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/secure_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final store = XSecureStore.instance;
  const key = 'ux.integration.session';

  tearDown(() => store.delete(key));

  testWidgets('a value round-trips through the OS credential store',
      (tester) async {
    await store.write(key, 'token-1');

    expect(await store.read(key), 'token-1');
  });

  testWidgets('a second write replaces the value', (tester) async {
    await store.write(key, 'token-1');

    await store.write(key, 'token-2');

    expect(await store.read(key), 'token-2');
  });

  testWidgets('a key that was never written reads null', (tester) async {
    expect(await store.read('ux.integration.absent'), isNull);
  });

  testWidgets('a deleted key reads null, and deleting it again succeeds',
      (tester) async {
    await store.write(key, 'token-1');

    await store.delete(key);
    await store.delete(key);

    expect(await store.read(key), isNull);
  });

  testWidgets('a value survives a byte for byte round trip', (tester) async {
    const value = 'ü•\u0000{"exp":1754380800}';

    await store.write(key, value);

    expect(await store.read(key), value);
  });
}
