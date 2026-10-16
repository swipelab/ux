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
}
