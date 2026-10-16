import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

class _Screen with Screen<void> {
  _Screen(this.child, {this.isModal = false});

  final Widget child;

  @override
  final bool isModal;

  @override
  Widget buildPresenter(BuildContext context) => child;
}

class _Sheet with Screen<void>, SheetScreen<void> {
  @override
  bool get isModal => true;

  @override
  Widget buildSheetBody(BuildContext context) =>
      TextButton(onPressed: () {}, child: const Text('body'));
}

FocusNode? get _primary => FocusManager.instance.primaryFocus;

void main() {
  testWidgets('Tab reaches a focusable on the home screen', (tester) async {
    final s = Center(
      child: Focus(
        debugLabel: 'target',
        child: SizedBox(width: 10, height: 10),
      ),
    );
    await tester.pumpWidget(XApp(router: XRouter(home: _Screen(s))));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_primary?.debugLabel, 'target');
  });

  testWidgets('a screen that shows holds focus in its own scope and asks '
      'for no keyboard', (tester) async {
    await tester.pumpWidget(
      XApp(
        router: XRouter(home: _Screen(const Center(child: TextField()))),
      ),
    );
    await tester.pumpAndSettle();
    expect(_primary, FocusScope.of(tester.element(find.byType(TextField))));
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('Esc pops the top screen where it is modal', (tester) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    final page = _Screen(const SizedBox());
    router.push(page);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(page.popped, isFalse);

    final modal = _Screen(const SizedBox(), isModal: true);
    router.push(modal);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(modal.popped, isTrue);
  });

  testWidgets('Esc in a modal sheet pops the sheet', (tester) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    final sheet = _Sheet();
    router.push(sheet);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(sheet.popped, isTrue);
  });

  testWidgets('Tab moves focus in an entry inserted beside the router\'s', (
    tester,
  ) async {
    final overlay = GlobalKey<OverlayState>();
    await tester.pumpWidget(
      XApp(
        router: XRouter(home: _Screen(const SizedBox())),
        overlayKey: overlay,
      ),
    );
    final a = FocusNode(debugLabel: 'a');
    final b = FocusNode(debugLabel: 'b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final entry = OverlayEntry(
      builder: (_) => Column(
        children: [
          Focus(focusNode: a, child: const SizedBox(width: 10, height: 10)),
          Focus(focusNode: b, child: const SizedBox(width: 10, height: 10)),
        ],
      ),
    );
    addTearDown(entry.dispose);
    addTearDown(entry.remove);
    overlay.currentState!.insert(entry);
    await tester.pump();
    a.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_primary, same(b));
  });
}
