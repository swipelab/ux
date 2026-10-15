import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux_example/secure_store_page.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const methods = MethodChannel('ux/secure_store');

  final values = <String, String>{};

  setUp(() {
    values.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      final args = (call.arguments as Map).cast<String, Object?>();
      final key = args['key'] as String;
      switch (call.method) {
        case 'read':
          return values[key];
        case 'write':
          values[key] = args['value'] as String;
        case 'delete':
          values.remove(key);
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  testWidgets('a written value reads back and a deleted one does not', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SecureStorePage()));

    await tester.tap(find.text('Write'));
    await tester.pumpAndSettle();
    expect(values, {'session': 'token-1'});

    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(find.text('read → token-1'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(values, isEmpty);

    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(find.text('read → null'), findsOneWidget);
  });

  testWidgets('a platform failure is shown with its code', (tester) async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'store_failed', message: 'OSStatus -25300');
    });
    await tester.pumpWidget(const MaterialApp(home: SecureStorePage()));

    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();

    expect(find.text('read ✗ store_failed: OSStatus -25300'), findsOneWidget);
  });
}
