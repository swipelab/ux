import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

const _width = 400.0;
const _frame = Duration(milliseconds: 16);
final _pageKey = GlobalKey();

class _Home with Screen<void> {
  @override
  Widget buildPresenter(BuildContext context) =>
      ColoredBox(color: Colors.black);
}

/// A screen filling its slot on the default transition, a slide on
/// [Curves.easeOut] over 300 ms.
class _Page with Screen<void> {
  @override
  Widget buildPresenter(BuildContext context) => ColoredBox(
    key: _pageKey,
    color: Colors.white,
    child: const SizedBox.expand(),
  );
}

/// A [_Page] whose back gesture and pop its fields turn off, and whose
/// [handleBack] counts the backs it is asked and consumes them while
/// [guards].
class _Gated extends _Page {
  bool swipeBack = true;
  bool pops = true;
  bool guards = false;
  int backs = 0;

  @override
  bool get canSwipeBack => swipeBack;

  @override
  bool get canPop => pops;

  @override
  bool handleBack() {
    backs++;
    return guards;
  }
}

/// A [_Gated] whose content counts the horizontal drags it takes.
class _Dragged extends _Gated {
  int drags = 0;

  @override
  Widget buildPresenter(BuildContext context) => GestureDetector(
    onHorizontalDragStart: (_) => drags++,
    child: super.buildPresenter(context),
  );
}

/// A sheet whose body fills it.
class _Sheet with Screen<void>, SheetScreen<void> {
  @override
  Widget buildSheetBody(BuildContext context) => const SizedBox.expand();
}

/// Pumps a router on [platform] and pushes [page], a [_Page] unless given,
/// settled unless [settle] is false.
Future<XRouter> _boot(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.iOS,
  bool settle = true,
  Screen<void>? page,
}) async {
  tester.view.physicalSize = const Size(_width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = XRouter(home: _Home());
  await tester.pumpWidget(
    XApp(
      router: router,
      theme: ThemeData(platform: platform),
    ),
  );
  router.push(page ?? _Page());
  if (settle) await tester.pumpAndSettle();
  return router;
}

/// Pumps a router on [platform], pushes a [_Sheet] and pushes [page] into
/// it, settled.
Future<XRouter> _bootSheet(
  WidgetTester tester,
  Screen<void> page, {
  TargetPlatform platform = TargetPlatform.iOS,
}) async {
  final sheet = _Sheet();
  final router = await _boot(tester, platform: platform, page: sheet);
  sheet.nestedHost.push(page);
  await tester.pumpAndSettle();
  return router;
}

double _offset(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(_pageKey)).dx;

/// Drags from x = 20 by [travel] in [steps] moves a frame apart, checking
/// at every frame once the drag is recognized that the screen's offset is
/// the finger's travel since the touch went down.
Future<TestGesture> _edgeDrag(
  WidgetTester tester,
  double travel, {
  required int steps,
}) async {
  var stamp = Duration.zero;
  final drag = await tester.createGesture();
  await drag.down(const Offset(20, 400), timeStamp: stamp);
  for (var i = 1; i <= steps; i++) {
    stamp += _frame;
    await drag.moveBy(Offset(travel / steps, 0), timeStamp: stamp);
    await tester.pump(_frame);
    final moved = travel * i / steps;
    if (moved > kTouchSlop) {
      expect(
        _offset(tester),
        moreOrLessEquals(moved, epsilon: 0.5),
        reason: 'at ${moved}px of travel',
      );
    }
  }
  return drag;
}

/// Checks the screen at each quarter of a settle over [span] that the frame
/// after a release starts: it leaves [from] on [Curves.easeOut] towards [to].
Future<void> _expectSettle(
  WidgetTester tester,
  double from,
  double to,
  Duration span,
) async {
  await tester.pump();
  for (var quarter = 0; quarter < 4; quarter++) {
    final expected = from + (to - from) * Curves.easeOut.transform(quarter / 4);
    expect(
      _offset(tester),
      moreOrLessEquals(expected, epsilon: 0.5),
      reason: 'at $quarter/4 of the settle',
    );
    await tester.pump(span * 0.25);
  }
  await tester.pumpAndSettle();
}

Future<void> _backGesture(
  WidgetTester tester,
  String method, [
  double? progress,
]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
  SystemChannels.backGesture.name,
  SystemChannels.backGesture.codec.encodeMethodCall(
    MethodCall(
      method,
      progress == null
          ? null
          : {
              'touchOffset': [0.0, 400.0],
              'progress': progress,
              'swipeEdge': 0,
            },
    ),
  ),
  (_) {},
);

void main() {
  testWidgets('an edge swipe keeps the screen under the finger from where '
      'the touch went down, and a release short of half springs it back on '
      'the transition\'s curve over 150 ms', (tester) async {
    final router = await _boot(tester);

    final drag = await _edgeDrag(tester, _width / 4, steps: 24);
    await drag.up();
    await _expectSettle(
      tester,
      _width / 4,
      0,
      const Duration(milliseconds: 150),
    );
    expect(_offset(tester), 0);
    expect(router.stack, hasLength(1));
  });

  testWidgets('an edge swipe released past half pops the screen on the '
      'transition\'s curve from where the finger left it', (tester) async {
    final router = await _boot(tester);

    final drag = await _edgeDrag(tester, _width * 0.6, steps: 40);
    await drag.up();
    await _expectSettle(
      tester,
      _width * 0.6,
      _width,
      const Duration(milliseconds: 300) * 0.4,
    );
    expect(router.stack, isEmpty);
  });

  testWidgets('an edge swipe begun while a spring back runs keeps the screen '
      'under the finger', (tester) async {
    await _boot(tester);

    final first = await _edgeDrag(tester, _width / 4, steps: 24);
    await first.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final second = await _edgeDrag(tester, _width / 2, steps: 24);
    await second.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a pop while a spring back runs moves the screen off from where '
      'it shows', (tester) async {
    final router = await _boot(tester);

    final drag = await _edgeDrag(tester, _width / 4, steps: 24);
    await drag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    var shown = _offset(tester);

    router.stack.single.pop();
    await tester.pump();
    while (find.byKey(_pageKey).evaluate().isNotEmpty) {
      expect(_offset(tester), greaterThanOrEqualTo(shown));
      shown = _offset(tester);
      await tester.pump(_frame);
    }
    expect(router.stack, isEmpty);
  });

  testWidgets('an edge swipe its screen turns off springs the screen back on '
      'the transition\'s curve over 150 ms, and the rest of its drag moves '
      'nothing and pops nothing', (tester) async {
    final page = _Gated();
    final router = await _boot(tester, page: page);

    final drag = await _edgeDrag(tester, _width / 4, steps: 24);
    page.swipeBack = false;
    router.pagesChanged();
    await tester.pump();
    await drag.moveBy(const Offset(_width / 2, 0));
    await drag.up();
    await _expectSettle(
      tester,
      _width / 4,
      0,
      const Duration(milliseconds: 150),
    );
    expect(router.stack, hasLength(1));
  });

  testWidgets('an edge swipe its screen turns off with no rebuild springs the '
      'screen back as the finger moves on, and its release pops nothing', (
    tester,
  ) async {
    final page = _Gated();
    final router = await _boot(tester, page: page);

    final drag = await _edgeDrag(tester, _width / 4, steps: 24);
    page.swipeBack = false;
    await drag.moveBy(const Offset(_width / 2, 0));
    await drag.up();
    await _expectSettle(
      tester,
      _width / 4,
      0,
      const Duration(milliseconds: 150),
    );
    expect(router.stack, hasLength(1));
  });

  testWidgets('an edge swipe its screen turns off with no rebuild as the '
      'finger lifts springs the screen back and pops nothing', (tester) async {
    final page = _Gated();
    final router = await _boot(tester, page: page);

    final drag = await _edgeDrag(tester, _width * 0.6, steps: 40);
    page.swipeBack = false;
    await drag.up();
    await _expectSettle(
      tester,
      _width * 0.6,
      0,
      const Duration(milliseconds: 150),
    );
    expect(router.stack, hasLength(1));
  });

  testWidgets('an edge drag on a screen that turns the back gesture off with '
      'no rebuild goes to the screen and pops nothing', (tester) async {
    final page = _Dragged();
    final router = await _boot(tester, page: page);

    page.swipeBack = false;
    await tester.dragFrom(const Offset(1, 400), const Offset(299, 0));
    await tester.pumpAndSettle();
    expect(router.stack, hasLength(1));
    expect(_offset(tester), 0);
    expect(page.drags, 1);
  });

  testWidgets('an edge swipe on a screen that turns the back gesture on with '
      'no rebuild pops the screen', (tester) async {
    final page = _Gated()..swipeBack = false;
    final router = await _boot(tester, page: page);

    page.swipeBack = true;
    await tester.dragFrom(const Offset(1, 400), const Offset(299, 0));
    await tester.pumpAndSettle();
    expect(router.stack, isEmpty);
  });

  testWidgets('a trackpad pan from the edge of a screen without the back '
      'gesture pops nothing', (tester) async {
    final router = await _boot(tester, page: _Gated()..swipeBack = false);

    final pan = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await pan.panZoomStart(const Offset(10, 400));
    for (var i = 1; i <= 10; i++) {
      await pan.panZoomUpdate(const Offset(10, 400), pan: Offset(30.0 * i, 0));
      await tester.pump(_frame);
    }
    await pan.panZoomEnd();
    await tester.pumpAndSettle();
    expect(router.stack, hasLength(1));
  });

  testWidgets('the edge swipe adds no semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await _boot(tester);

    expect(find.semantics.byAction(SemanticsAction.scrollLeft), findsNothing);
    semantics.dispose();
  });

  testWidgets('an edge swipe whose theme leaves iOS springs the screen back, '
      'and its release pops nothing', (tester) async {
    final router = await _boot(tester);

    final drag = await _edgeDrag(tester, _width / 4, steps: 24);
    await tester.pumpWidget(
      XApp(
        router: router,
        theme: ThemeData(platform: TargetPlatform.android),
      ),
    );
    await tester.pumpAndSettle();
    await drag.up();
    await tester.pumpAndSettle();
    expect(_offset(tester), 0);
    expect(router.stack, hasLength(1));
  });

  testWidgets('a screen popped during an edge swipe leaves from where the '
      'finger left it', (tester) async {
    final router = await _boot(tester);

    final drag = await _edgeDrag(tester, _width / 4, steps: 24);
    router.stack.single.pop();
    await tester.pump();
    await drag.up();
    await _expectSettle(
      tester,
      _width / 4,
      _width,
      const Duration(milliseconds: 300) * 0.75,
    );
    expect(find.byKey(_pageKey), findsNothing);
  });

  testWidgets('a predictive back sets the screen at the gesture\'s progress, '
      'and its cancel springs it back on the transition\'s curve over 150 ms', (
    tester,
  ) async {
    final router = await _boot(tester, platform: TargetPlatform.android);

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.25);
    await tester.pump();
    expect(_offset(tester), moreOrLessEquals(_width / 4, epsilon: 0.5));

    await _backGesture(tester, 'cancelBackGesture');
    await _expectSettle(
      tester,
      _width / 4,
      0,
      const Duration(milliseconds: 150),
    );
    expect(router.stack, hasLength(1));
  });

  testWidgets('a predictive back its screen turns off springs the screen back '
      'on the transition\'s curve over 150 ms, and its commit pops nothing', (
    tester,
  ) async {
    final page = _Gated();
    final router = await _boot(
      tester,
      platform: TargetPlatform.android,
      page: page,
    );

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.25);
    await tester.pump();
    page.pops = false;
    router.pagesChanged();
    await tester.pump();
    await _backGesture(tester, 'updateBackGestureProgress', 0.5);
    await _backGesture(tester, 'commitBackGesture');
    await _expectSettle(
      tester,
      _width / 4,
      0,
      const Duration(milliseconds: 150),
    );
    expect(router.stack, hasLength(1));
  });

  testWidgets('a predictive back whose screen turns the back gesture off '
      'through a rebuild drags the screen on, and its commit goes back '
      'through handleBack', (tester) async {
    final page = _Gated();
    final router = await _boot(
      tester,
      platform: TargetPlatform.android,
      page: page,
    );

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.25);
    await tester.pump();
    page.swipeBack = false;
    router.pagesChanged();
    await tester.pump();
    await _backGesture(tester, 'updateBackGestureProgress', 0.5);
    await tester.pump();
    expect(_offset(tester), moreOrLessEquals(_width / 2, epsilon: 0.5));

    await _backGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(page.backs, 1);
    expect(router.stack, isEmpty);
  });

  testWidgets('a predictive back leaves a screen without the back gesture in '
      'place, and its commit goes back through handleBack', (tester) async {
    final page = _Gated()
      ..swipeBack = false
      ..guards = true;
    final router = await _boot(
      tester,
      platform: TargetPlatform.android,
      page: page,
    );

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.25);
    await tester.pump();
    expect(_offset(tester), 0);

    await _backGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(page.backs, 1);
    expect(router.stack, hasLength(1));
  });

  testWidgets('a predictive back\'s commit that handleBack consumes springs '
      'the screen back on the transition\'s curve over 150 ms', (tester) async {
    final page = _Gated()..guards = true;
    final router = await _boot(
      tester,
      platform: TargetPlatform.android,
      page: page,
    );

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.25);
    await tester.pump();
    await _backGesture(tester, 'commitBackGesture');
    await _expectSettle(
      tester,
      _width / 4,
      0,
      const Duration(milliseconds: 150),
    );
    expect(page.backs, 1);
    expect(router.stack, hasLength(1));
  });

  testWidgets('a predictive back\'s commit that handleBack declines pops the '
      'screen from where the gesture left it', (tester) async {
    final page = _Gated();
    final router = await _boot(
      tester,
      platform: TargetPlatform.android,
      page: page,
    );

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.25);
    await tester.pump();
    await _backGesture(tester, 'commitBackGesture');
    await _expectSettle(
      tester,
      _width / 4,
      _width,
      const Duration(milliseconds: 300) * 0.75,
    );
    expect(page.backs, 1);
    expect(router.stack, isEmpty);
  });

  testWidgets('a pushed screen slides in on its transition\'s curve', (
    tester,
  ) async {
    await _boot(tester, settle: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    expect(
      _offset(tester),
      moreOrLessEquals(_width * (1 - Curves.easeOut.transform(0.25))),
    );
  });

  testWidgets('system back on a sheet asks its nested page\'s handleBack, and '
      'keeps the page when it consumes the back', (tester) async {
    final page = _Gated()..guards = true;
    await _bootSheet(tester, page);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(page.backs, 1);
    expect(page.popped, isFalse);
  });

  testWidgets('system back on a sheet keeps a nested page that cannot pop', (
    tester,
  ) async {
    final page = _Gated()..pops = false;
    await _bootSheet(tester, page);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(page.popped, isFalse);
  });

  testWidgets('a predictive back on a sheet with a nested page drags the '
      'nested page alone, and its commit asks the page\'s handleBack once and '
      'keeps the page when it consumes the back', (tester) async {
    final page = _Gated()..guards = true;
    await _bootSheet(tester, page, platform: TargetPlatform.android);
    final left = _offset(tester);
    final width = tester.getSize(find.byKey(_pageKey)).width;

    await _backGesture(tester, 'startBackGesture', 0);
    await _backGesture(tester, 'updateBackGestureProgress', 0.25);
    await tester.pump();
    expect(_offset(tester), moreOrLessEquals(left + width / 4, epsilon: 0.5));

    await _backGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(page.backs, 1);
    expect(page.popped, isFalse);
  });

  testWidgets('an edge swipe on a sheet whose nested page cannot pop pops '
      'nothing', (tester) async {
    final page = _Gated()..pops = false;
    final router = await _bootSheet(tester, page);

    await tester.dragFrom(const Offset(10, 600), const Offset(299, 0));
    await tester.pumpAndSettle();
    expect(page.popped, isFalse);
    expect(router.stack, hasLength(1));
  });
}
