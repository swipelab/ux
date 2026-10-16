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

/// Focuses a node in an entry inserted beside the router's.
Future<FocusNode> _focusBeside(
  WidgetTester tester,
  GlobalKey<OverlayState> overlay,
) async {
  final node = FocusNode(debugLabel: 'beside');
  addTearDown(node.dispose);
  final entry = OverlayEntry(
    builder: (_) =>
        Focus(focusNode: node, child: const SizedBox(width: 10, height: 10)),
  );
  addTearDown(entry.dispose);
  addTearDown(entry.remove);
  overlay.currentState!.insert(entry);
  await tester.pump();
  node.requestFocus();
  await tester.pump();
  return node;
}

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

  testWidgets('sheets that mount under another screen leave it the focus', (
    tester,
  ) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    final sheet = _Sheet();
    router.push(sheet);
    sheet.nestedHost.push(_Sheet());
    router.push(
      _Screen(
        const Focus(
          debugLabel: 'target',
          child: SizedBox(width: 10, height: 10),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_primary?.debugLabel, 'target');
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

  testWidgets('a push from an entry inserted beside the router\'s focuses '
      'the new screen', (tester) async {
    final overlay = GlobalKey<OverlayState>();
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router, overlayKey: overlay));
    await _focusBeside(tester, overlay);
    router.push(_Screen(const SizedBox(key: Key('page'))));
    await tester.pumpAndSettle();
    expect(
      _primary,
      FocusScope.of(tester.element(find.byKey(const Key('page')))),
    );
  });

  testWidgets('a push in the top sheet leaves focus in an entry inserted '
      'beside the router\'s', (tester) async {
    final overlay = GlobalKey<OverlayState>();
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router, overlayKey: overlay));
    final sheet = _Sheet();
    router.push(sheet);
    await tester.pumpAndSettle();
    final node = await _focusBeside(tester, overlay);
    sheet.nestedHost.push(_Screen(const SizedBox()));
    await tester.pumpAndSettle();
    expect(_primary, same(node));
  });
}
