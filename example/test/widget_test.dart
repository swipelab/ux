import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux_example/main.dart';

void main() {
  testWidgets('ChatScreen renders', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: ChatScreen()));
    expect(find.text('UxKeyboard Chat'), findsOneWidget);
    expect(find.text('Type a message...'), findsOneWidget);
  });
}
