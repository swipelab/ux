import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

const _small = Rect.fromLTWH(20, 40, 40, 40);
const _large = Rect.fromLTWH(100, 200, 200, 120);

class _Screen with Screen<void> {
  _Screen(this.heroRect, {this.transitionDuration = _slide});

  static const _slide = Duration(milliseconds: 300);

  final Rect heroRect;

  @override
  final Duration transitionDuration;

  @override
  Widget buildPresenter(BuildContext context) => Stack(
    children: [
      Positioned.fromRect(
        rect: heroRect,
        child: const ScreenHero(tag: 'avatar', child: _Avatar()),
      ),
    ],
  );
}

/// A tab host with its hero at [_small], keeping one detail per tab and
/// showing the selected tab's.
class _Tabs extends _Screen with ScreenShell {
  _Tabs() : super(_small);

  int tab = 0;
  final details = <int, Screen>{};

  void select(int index) {
    tab = index;
    pagesChanged();
  }

  @override
  bool accept(Screen screen) {
    details[tab] = screen;
    return true;
  }

  @override
  void remove(Screen screen) =>
      details.removeWhere((_, hosted) => identical(hosted, screen));

  @override
  Iterable<Screen> get pages => [?details[tab]];

  @override
  Iterable<Screen> get hosted => details.values;
}

class _Avatar extends StatelessWidget {
  const _Avatar();

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blue);
}

Finder get _avatar => find.byType(_Avatar);

Future<XRouter> _boot(WidgetTester tester, {TargetPlatform? platform}) async {
  final router = XRouter(home: _Screen(_small));
  await tester.pumpWidget(
    XApp(
      router: router,
      theme: ThemeData(platform: platform),
    ),
  );
  return router;
}

/// Pumps, in a [MaterialApp]'s overlay and [inset] in from it, a
/// [ScreenStack] over a screen with its hero at [_small] that holds the
/// screens [stack] holds, each [place] in from the stack; while [stack] holds
/// `null` there is no stack.
Future<void> _bootStack(
  WidgetTester tester,
  ValueNotifier<List<Screen>?> stack, {
  EdgeInsets inset = EdgeInsets.zero,
  EdgeInsets place = EdgeInsets.zero,
}) => tester.pumpWidget(
  MaterialApp(
    home: Padding(
      padding: inset,
      child: ValueListenableBuilder(
        valueListenable: stack,
        builder: (context, screens, _) => screens == null
            ? const SizedBox()
            : ScreenStack(
                home: _Screen(_small),
                stack: screens,
                place: (context, screen, slot) =>
                    Padding(padding: place, child: slot),
              ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a hero flies from its place on the screen below to its place '
      'on a pushed screen over the push, and back over the pop', (
    tester,
  ) async {
    final router = await _boot(tester);
    final page = _Screen(_large);

    router.push(page);
    await tester.pump();
    await tester.pump();
    expect(_avatar, findsOneWidget);
    expect(tester.getRect(_avatar), rectMoreOrLessEquals(_small));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.getRect(_avatar),
      rectMoreOrLessEquals(Rect.lerp(_small, _large, 0.5)!),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(_avatar.last), _large);

    page.pop();
    await tester.pump();
    await tester.pump();
    expect(_avatar, findsOneWidget);
    expect(tester.getRect(_avatar), rectMoreOrLessEquals(_large));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.getRect(_avatar),
      rectMoreOrLessEquals(Rect.lerp(_large, _small, 0.5)!),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(_avatar), _small);
  });

  testWidgets('a push with no transition leaves both heroes in place', (
    tester,
  ) async {
    final router = await _boot(tester);

    router.push(_Screen(_large, transitionDuration: Duration.zero));
    await tester.pumpAndSettle();
    expect(tester.getRect(_avatar.first), _small);
    expect(tester.getRect(_avatar.last), _large);
  });

  testWidgets('a pop that a back gesture commits leaves both heroes on their '
      'screens', (tester) async {
    final router = await _boot(tester, platform: TargetPlatform.iOS);
    router.push(_Screen(_large));
    await tester.pumpAndSettle();

    final swipe = await tester.startGesture(const Offset(20, 300));
    for (var i = 0; i < 3; i++) {
      await swipe.moveBy(const Offset(200, 0));
      await tester.pump();
    }
    await swipe.up();
    await tester.pump();
    await tester.pump();
    expect(_avatar, findsNWidgets(2));
    expect(tester.getRect(_avatar.first), _small);
    await tester.pumpAndSettle();
    expect(router.stack, isEmpty);
  });

  testWidgets('a hero flies from where it shows on the screen below to where '
      'it shows on a pushed screen, with the stack and the screen placed in '
      'from the overlay', (tester) async {
    final stack = ValueNotifier<List<Screen>?>([]);
    await _bootStack(
      tester,
      stack,
      inset: const EdgeInsets.only(left: 10, top: 20),
      place: const EdgeInsets.only(left: 50, top: 30),
    );
    final begin = _small.shift(const Offset(10, 20));
    final end = _large.shift(const Offset(60, 50));

    stack.value = [_Screen(_large)];
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(_avatar), rectMoreOrLessEquals(begin));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.getRect(_avatar),
      rectMoreOrLessEquals(Rect.lerp(begin, end, 0.5)!),
    );
  });

  testWidgets('a stack that leaves mid-flight takes its shuttles out of the '
      'overlay', (tester) async {
    final stack = ValueNotifier<List<Screen>?>([]);
    await _bootStack(tester, stack);

    stack.value = [_Screen(_large)];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_avatar, findsOneWidget);
    stack.value = null;
    await tester.pumpAndSettle();
    expect(_avatar, findsNothing);
  });

  testWidgets('a flight to a screen that hides lands, and the hero below '
      'keeps its place once the hidden screen leaves', (tester) async {
    final tabs = _Tabs();
    final router = XRouter(home: tabs);
    await tester.pumpWidget(XApp(router: router));
    final detail = _Screen(_large);

    router.push(detail);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    tabs.select(1);
    await tester.pump();
    expect(_avatar, findsOneWidget);
    await tester.pump();
    expect(tester.getRect(_avatar), _small);
    await tester.pump(const Duration(milliseconds: 50));
    detail.pop();
    await tester.pumpAndSettle();
    expect(tester.getRect(_avatar), _small);
  });
}
