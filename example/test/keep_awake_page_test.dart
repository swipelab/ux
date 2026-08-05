import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux_example/keep_awake_page.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const window = MethodChannel('ux/window');
  const url = MethodChannel('ux/url');

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(window, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(url, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(window, null);
    messenger.setMockMethodCallHandler(url, null);
  });

  testWidgets('the switch holds and releases the screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: KeepAwakePage()));

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(calls.last.arguments, {'enabled': true});

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(calls.last.arguments, {'enabled': false});
  });

  testWidgets('leaving the page releases a held screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: KeepAwakePage()));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(calls.last.arguments, {'enabled': false});
  });

  testWidgets('the settings button reports what the OS answered',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: KeepAwakePage()));

    await tester.tap(find.text('Open app settings'));
    await tester.pumpAndSettle();

    expect(calls.map((c) => c.method), contains('openAppSettings'));
    expect(find.text('settings opened'), findsOneWidget);
  }, skip: !(Platform.isIOS || Platform.isAndroid || Platform.isMacOS));
}
