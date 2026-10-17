import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

class _Screen with Screen<void> {
  _Screen(this.child, {this.isModal = false, this.canPop = true});

  final Widget child;

  @override
  final bool isModal;

  @override
  final bool canPop;

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

class _PassingDispatcher extends ActionDispatcher {
  const _PassingDispatcher(this.above, [this.invoked]);

  final ActionDispatcher above;

  final List<Action<Intent>>? invoked;

  @override
  Object? invokeAction(
    Action<Intent> action,
    Intent intent, [
    BuildContext? context,
  ]) {
    invoked?.add(action);
    return above.invokeAction(action, intent, context);
  }

  @override
  (bool, Object?) invokeActionIfEnabled(
    Action<Intent> action,
    Intent intent, [
    BuildContext? context,
  ]) => above.invokeActionIfEnabled(action, intent, context);
}

class _Disabled extends DismissAction {
  @override
  bool isEnabled(DismissIntent intent) => false;

  @override
  void invoke(DismissIntent intent) {}
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

  testWidgets('Esc pops the top screen where its back is enabled', (
    tester,
  ) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    final page = _Screen(const SizedBox());
    router.push(page);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(page.popped, isTrue);

    final pinned = _Screen(const SizedBox(), canPop: false);
    router.push(pinned);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(pinned.popped, isFalse);
  });

  testWidgets('Esc in a Scaffold with no drawer open pops its screen', (
    tester,
  ) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    final control = FocusNode();
    addTearDown(control.dispose);
    final page = _Screen(
      Scaffold(
        body: Focus(
          focusNode: control,
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    router.push(page);
    await tester.pumpAndSettle();
    control.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(page.popped, isTrue);
  });

  testWidgets('Esc pops a modal top screen whose back is disabled', (
    tester,
  ) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    final modal = _Screen(const SizedBox(), isModal: true, canPop: false);
    router.push(modal);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(modal.popped, isTrue);
  });

  testWidgets(
    'Esc in a text field in a Scaffold unfocuses it, and a second '
    'Esc pops its screen',
    (tester) async {
      final router = XRouter(home: _Screen(const SizedBox()));
      await tester.pumpWidget(XApp(router: router));
      final field = FocusNode();
      addTearDown(field.dispose);
      final page = _Screen(
        Scaffold(
          body: Center(child: TextField(focusNode: field)),
        ),
      );
      router.push(page);
      await tester.pumpAndSettle();
      field.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(field.hasFocus, isFalse);
      expect(page.popped, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(page.popped, isTrue);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Esc in a text field in a Scaffold under an app\'s dispatcher that '
    'passes its calls to XApp\'s unfocuses it, and a second Esc pops its '
    'screen',
    (tester) async {
      final router = XRouter(home: _Screen(const SizedBox()));
      await tester.pumpWidget(XApp(router: router));
      final field = FocusNode();
      addTearDown(field.dispose);
      final page = _Screen(
        Builder(
          builder: (context) => Actions(
            dispatcher: _PassingDispatcher(Actions.of(context)),
            actions: const {},
            child: Scaffold(
              body: Center(child: TextField(focusNode: field)),
            ),
          ),
        ),
      );
      router.push(page);
      await tester.pumpAndSettle();
      field.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(field.hasFocus, isFalse);
      expect(page.popped, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(page.popped, isTrue);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('Esc that a Scaffold hands on to an action around it goes '
      'through an app\'s dispatcher around that action', (tester) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    final invoked = <Action<Intent>>[];
    final appAction = CallbackAction<DismissIntent>(onInvoke: (_) => null);
    final control = FocusNode();
    addTearDown(control.dispose);
    final page = _Screen(
      Builder(
        builder: (context) => Actions(
          dispatcher: _PassingDispatcher(Actions.of(context), invoked),
          actions: const {},
          child: Actions(
            actions: {DismissIntent: appAction},
            child: Scaffold(
              body: Focus(
                focusNode: control,
                child: const SizedBox(width: 10, height: 10),
              ),
            ),
          ),
        ),
      ),
    );
    router.push(page);
    await tester.pumpAndSettle();
    control.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(invoked, [appAction]);
  });

  testWidgets('Esc in a text field with its menu shown hides the menu and '
      'leaves the field focused', (tester) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    final field = FocusNode();
    addTearDown(field.dispose);
    router.push(_Screen(Center(child: TextField(focusNode: field))));
    await tester.pumpAndSettle();
    field.requestFocus();
    await tester.pump();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    editable.showToolbar();
    await tester.pumpAndSettle();
    expect(editable.selectionOverlay!.toolbarIsVisible, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(editable.selectionOverlay!.toolbarIsVisible, isFalse);
    expect(field.hasFocus, isTrue);
  });

  testWidgets('Esc in a text field in an open drawer closes the drawer', (
    tester,
  ) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    final scaffold = GlobalKey<ScaffoldState>();
    final field = FocusNode();
    addTearDown(field.dispose);
    final page = _Screen(
      Scaffold(
        key: scaffold,
        drawer: Drawer(child: TextField(focusNode: field)),
        body: const SizedBox(),
      ),
    );
    router.push(page);
    await tester.pumpAndSettle();
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    field.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(scaffold.currentState!.isDrawerOpen, isFalse);
    expect(page.popped, isFalse);
  });

  testWidgets('Esc on an overridable action goes to the nearest enabled one '
      'around it, and with none, to its default', (tester) async {
    final overlay = GlobalKey<OverlayState>();
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router, overlayKey: overlay));
    var defaults = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    final overridable = Builder(
      builder: (context) => Actions(
        actions: {
          DismissIntent: Action<DismissIntent>.overridable(
            defaultAction: CallbackAction(onInvoke: (_) => defaults++),
            context: context,
          ),
        },
        child: Focus(
          focusNode: node,
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    final page = _Screen(Scaffold(body: overridable));
    router.push(page);
    await tester.pumpAndSettle();
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(page.popped, isTrue);
    expect(defaults, 0);

    final entry = OverlayEntry(builder: (_) => overridable);
    addTearDown(entry.dispose);
    addTearDown(entry.remove);
    overlay.currentState!.insert(entry);
    await tester.pump();
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(defaults, 1);
  });

  testWidgets('Esc on an overridable action whose default is disabled, with '
      'no enabled one around it, goes unhandled', (tester) async {
    final overlay = GlobalKey<OverlayState>();
    await tester.pumpWidget(
      XApp(
        router: XRouter(home: _Screen(const SizedBox())),
        overlayKey: overlay,
      ),
    );
    final node = FocusNode();
    addTearDown(node.dispose);
    final entry = OverlayEntry(
      builder: (_) => Builder(
        builder: (context) => Actions(
          actions: {
            DismissIntent: Action<DismissIntent>.overridable(
              defaultAction: _Disabled(),
              context: context,
            ),
          },
          child: Focus(
            focusNode: node,
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      ),
    );
    addTearDown(entry.dispose);
    addTearDown(entry.remove);
    overlay.currentState!.insert(entry);
    await tester.pump();
    node.requestFocus();
    await tester.pump();
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isFalse);
  });

  testWidgets('Esc that an action hands on through an app\'s dispatcher '
      'pops its screen', (tester) async {
    final router = XRouter(home: _Screen(const SizedBox()));
    await tester.pumpWidget(XApp(router: router));
    var defaults = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    final page = _Screen(
      Actions(
        dispatcher: const ActionDispatcher(),
        actions: const {},
        child: Builder(
          builder: (context) => Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (intent) =>
                    Actions.handler<Intent>(context, intent)?.call(),
              ),
            },
            child: Scaffold(
              body: Builder(
                builder: (context) => Actions(
                  actions: {
                    DismissIntent: Action<DismissIntent>.overridable(
                      defaultAction: CallbackAction(
                        onInvoke: (_) => defaults++,
                      ),
                      context: context,
                    ),
                  },
                  child: Focus(
                    focusNode: node,
                    child: const SizedBox(width: 10, height: 10),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    router.push(page);
    await tester.pumpAndSettle();
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(page.popped, isTrue);
    expect(defaults, 0);
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
