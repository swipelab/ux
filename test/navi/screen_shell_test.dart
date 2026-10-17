import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

/// A tab host keeping one detail per tab and showing the selected tab's.
/// While [wide], it places its details in a pane right of its 300-wide list
/// and marks them beside it.
class _Shell with Screen<void>, Emitter, ScreenShell {
  _Shell({required this.wide});

  bool wide;
  int tab = 0;
  int backs = 0;
  final details = <int, Screen>{};
  final events = <String>[];

  void select(int index) {
    tab = index;
    notifyListeners();
    pagesChanged();
  }

  @override
  bool accept(Screen screen) {
    final old = details[tab];
    details[tab] = screen;
    notifyListeners();
    old?.pop();
    return true;
  }

  @override
  void remove(Screen screen) {
    details.removeWhere((_, hosted) => identical(hosted, screen));
    notifyListeners();
    pagesChanged();
  }

  @override
  Iterable<Screen> get pages => [?details[tab]];

  @override
  Iterable<Screen> get hosted => details.values;

  @override
  void show(Screen screen) {
    tab = details.keys.firstWhere((key) => identical(details[key], screen));
    notifyListeners();
  }

  @override
  Widget place(BuildContext context, Screen screen, Widget slot) => wide
      ? Padding(padding: const EdgeInsets.only(left: 300), child: slot)
      : slot;

  @override
  bool isBeside(Screen screen) => wide;

  @override
  bool handleBack() {
    final shown = details[tab];
    if (shown == null) return false;
    backs++;
    shown.pop();
    return true;
  }

  @override
  void onActive() => events.add('active');

  @override
  void onInactive() => events.add('inactive');

  @override
  Widget buildPresenter(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 300,
      child: TextButton(onPressed: () {}, child: const Text('row')),
    ),
  );
}

/// A detail screen, equal to any other with its [id]. While [wide] is true,
/// its transition wraps the content in a Padding.
class _Detail with Screen<String>, Dispose {
  _Detail(this.id, {this.wide});

  final String id;
  final ValueNotifier<bool>? wide;
  final events = <String>[];
  int inits = 0;

  @override
  bool operator ==(Object other) => other is _Detail && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  void onActive() => events.add('active');

  @override
  void onInactive() => events.add('inactive');

  @override
  void onRemoved() {
    events.add('removed');
    super.onRemoved();
  }

  @override
  void dispose() {
    events.add('disposed');
    super.dispose();
  }

  @override
  Widget buildTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) {
    final wide = this.wide;
    if (wide == null) return super.buildTransition(context, animation, child);
    return ListenableBuilder(
      listenable: wide,
      builder: (context, _) => wide.value
          ? Padding(padding: const EdgeInsets.only(left: 300), child: child)
          : child,
    );
  }

  @override
  Widget buildPresenter(BuildContext context) => _DetailView(this);
}

class _DetailView extends StatefulWidget {
  const _DetailView(this.detail);

  final _Detail detail;

  @override
  State<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends State<_DetailView> {
  @override
  void initState() {
    super.initState();
    widget.detail.inits++;
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: TextButton(onPressed: () {}, child: Text(widget.detail.id)),
  );
}

Future<(_Shell, XRouter)> _boot(
  WidgetTester tester, {
  bool wide = false,
}) async {
  tester.view.physicalSize = const Size(1000, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final shell = _Shell(wide: wide);
  final router = XRouter(home: shell);
  await tester.pumpWidget(XApp(router: router));
  return (shell, router);
}

FocusNode _node(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label, skipOffstage: false)));

FocusNode? get _primary => FocusManager.instance.primaryFocus;

Future<void> _backGesture(
  WidgetTester tester,
  String method, [
  Map<String, Object?>? arguments,
]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
  SystemChannels.backGesture.name,
  SystemChannels.backGesture.codec.encodeMethodCall(
    MethodCall(method, arguments),
  ),
  (_) {},
);

void main() {
  group('a shell hiding the screens it does not show', () {
    testWidgets('a tab switch hides the shown screen and makes the shell '
        'active', (tester) async {
      final handlesBack = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
            handlesBack.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final (shell, router) = await _boot(tester);
      final chat = _Detail('chat');
      router.push(chat);
      await tester.pumpAndSettle();
      expect(handlesBack.last, isTrue);

      shell.select(1);
      await tester.pumpAndSettle();
      expect(router.pages, [shell]);
      expect(find.text('chat'), findsNothing);
      expect(chat.events, ['active', 'inactive']);
      expect(shell.events, ['active', 'inactive', 'active']);
      expect(handlesBack.last, isFalse);

      shell.select(0);
      await tester.pumpAndSettle();
      expect(find.text('chat'), findsOneWidget);
      expect(chat.events, ['active', 'inactive', 'active']);
      expect(shell.events, ['active', 'inactive', 'active', 'inactive']);
    });

    testWidgets('a hidden screen stays alive offstage, hands its focus to '
        'the shell and shows again at once', (tester) async {
      final (shell, router) = await _boot(tester);
      final chat = _Detail('chat');
      router.push(chat);
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(_DetailView));
      final shown = tester.getTopLeft(find.text('chat'));
      _node(tester, 'chat').requestFocus();
      await tester.pump();

      shell.select(1);
      await tester.pump();
      expect(find.text('chat'), findsNothing);
      final hidden = tester.element(find.text('chat', skipOffstage: false));
      expect(TickerMode.valuesOf(hidden).enabled, isFalse);
      expect(_primary, FocusScope.of(tester.element(find.text('row'))));

      shell.select(0);
      await tester.pump();
      expect(tester.state(find.byType(_DetailView)), same(state));
      expect(tester.getTopLeft(find.text('chat')), shown);
      expect(chat.inits, 1);
    });

    testWidgets('the router lists the shown screens apart from every hosted '
        'one', (tester) async {
      final (shell, router) = await _boot(tester);
      final chat = _Detail('chat');
      final notes = _Detail('notes');
      router.push(chat);
      await tester.pumpAndSettle();
      shell.select(1);
      router.push(notes);
      await tester.pumpAndSettle();

      expect(router.pages, [shell, notes]);
      expect(router.hosted, [shell, chat, notes]);
    });

    testWidgets('a push equal to a hidden screen shows it, and popAll pops '
        'hidden screens', (tester) async {
      final (shell, router) = await _boot(tester);
      final chat = _Detail('chat');
      final notes = _Detail('notes');
      final opened = router.push(chat);
      await tester.pumpAndSettle();
      shell.select(1);
      router.push(notes);
      await tester.pumpAndSettle();

      final again = _Detail('chat');
      final reopened = router.push(again);
      await tester.pumpAndSettle();
      expect(shell.tab, 0);
      expect(router.pages.last, same(chat));
      expect(find.text('chat'), findsOneWidget);
      expect(again.inits, 0);

      router.popAll();
      await tester.pumpAndSettle();
      expect(notes.popped, isTrue);
      expect(await reopened, isNull);
      expect(await opened, isNull);
      expect(router.hosted, [shell]);
    });

    testWidgets('popping a hidden screen completes its removal after the '
        'frame of its pop, where its shell may re-render the router', (
      tester,
    ) async {
      final (shell, router) = await _boot(tester);
      final chat = _Detail('chat');
      router.push(chat);
      await tester.pumpAndSettle();
      shell.select(1);
      await tester.pumpAndSettle();

      chat.pop('closed');
      await tester.pump();
      expect(chat.events, ['active', 'inactive', 'removed', 'disposed']);
      expect(shell.details, isEmpty);
    });
  });

  group('a shell placing screens beside it', () {
    testWidgets('a placed screen fills its pane under the window '
        'MediaQuery, and leaves within it', (tester) async {
      final (_, router) = await _boot(tester, wide: true);
      router.push(_Detail('one'));
      await tester.pumpAndSettle();

      final view = find.widgetWithText(_DetailView, 'one');
      expect(tester.getRect(view), const Rect.fromLTWH(300, 0, 700, 600));
      expect(MediaQuery.sizeOf(tester.element(view)), const Size(1000, 600));

      router.push(_Detail('two'));
      await tester.pump();
      expect(tester.getTopLeft(view).dx, greaterThanOrEqualTo(300));
    });

    testWidgets('focus stays where it is as beside screens show and replace '
        'each other, and focus inside one that leaves goes to the shell', (
      tester,
    ) async {
      final (shell, router) = await _boot(tester, wide: true);
      final row = _node(tester, 'row')..requestFocus();
      await tester.pump();

      router.push(_Detail('one'));
      await tester.pumpAndSettle();
      expect(_primary, same(row));

      router.push(_Detail('two'));
      await tester.pumpAndSettle();
      expect(_primary, same(row));

      _node(tester, 'two').requestFocus();
      await tester.pump();
      router.push(_Detail('three'));
      await tester.pumpAndSettle();
      expect(_primary, same(row));

      _node(tester, 'three').requestFocus();
      await tester.pump();
      shell.select(1);
      await tester.pump();
      expect(_primary, same(row));
    });

    testWidgets('Tab and Shift+Tab cross between the shell and a beside '
        'screen', (tester) async {
      final (_, router) = await _boot(tester, wide: true);
      router.push(_Detail('detail'));
      await tester.pumpAndSettle();
      final row = _node(tester, 'row')..requestFocus();
      final detail = _node(tester, 'detail');
      await tester.pump();

      final forward = <FocusNode?>[];
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        forward.add(_primary);
      }
      expect(forward, [detail, row, detail, row]);

      final backward = <FocusNode?>[];
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      for (var i = 0; i < 2; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        backward.add(_primary);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(backward, [detail, row]);
    });

    testWidgets('a beside screen takes no back gesture, so back reaches the '
        'shell', (tester) async {
      final (shell, router) = await _boot(tester, wide: true);
      final detail = _Detail('detail');
      router.push(detail);
      await tester.pumpAndSettle();

      await tester.dragFrom(const Offset(310, 300), const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(detail.popped, isFalse);

      await _backGesture(tester, 'startBackGesture', {
        'touchOffset': [310.0, 300.0],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await _backGesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(shell.backs, 1);
      expect(detail.popped, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a hosted screen keeps its State when its placement and '
        'beside mark change', (tester) async {
      final (shell, router) = await _boot(tester, wide: true);
      final detail = _Detail('detail');
      router.push(detail);
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(_DetailView));
      expect(tester.getTopLeft(find.byType(_DetailView)), const Offset(300, 0));

      shell.wide = false;
      shell.pagesChanged();
      await tester.pump();
      expect(tester.getTopLeft(find.byType(_DetailView)), Offset.zero);
      expect(tester.state(find.byType(_DetailView)), same(state));
      expect(detail.inits, 1);
    });

    testWidgets('a screen keeps its State when its transition changes shape', (
      tester,
    ) async {
      final (_, router) = await _boot(tester);
      final wide = ValueNotifier(true);
      addTearDown(wide.dispose);
      final detail = _Detail('detail', wide: wide);
      router.push(detail);
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(_DetailView));

      wide.value = false;
      await tester.pump();
      expect(tester.state(find.byType(_DetailView)), same(state));
      expect(detail.inits, 1);
    });
  });
}
