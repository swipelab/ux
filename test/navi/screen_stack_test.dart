import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

/// A screen filled by a button labelled [label] that logs its taps to [taps].
class _Button with Screen<void> {
  _Button(this.label, this.taps);

  final String label;
  final List<String> taps;

  @override
  Widget buildPresenter(BuildContext context) => SizedBox.expand(
    child: TextButton(onPressed: () => taps.add(label), child: Text(label)),
  );
}

/// A screen with no transition that counts the builds of its content after
/// its pop.
class _Instant with Screen<void> {
  int poppedBuilds = 0;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) => child;

  @override
  Widget buildPresenter(BuildContext context) => Builder(
    builder: (context) {
      if (popped) poppedBuilds++;
      return const Text('instant');
    },
  );
}

void main() {
  testWidgets('a screen takes taps as it enters, and a tap on it as it leaves '
      'reaches the screen under it', (tester) async {
    final taps = <String>[];
    final router = XRouter(home: _Button('home', taps));
    await tester.pumpWidget(XApp(router: router));

    router.push(_Button('page', taps));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tapAt(tester.getCenter(find.text('page')));
    await tester.pumpAndSettle();

    router.stack.single.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(tester.getCenter(find.text('page')));
    await tester.pumpAndSettle();
    expect(taps, ['page', 'home']);
  });

  testWidgets('a screen with a zero transition duration leaves in the frame '
      'after its pop, building nothing more', (tester) async {
    final router = XRouter(home: _Button('home', []));
    await tester.pumpWidget(XApp(router: router));
    final page = _Instant();
    router.push(page);
    await tester.pumpAndSettle();

    page.pop();
    await tester.pump();
    expect(page.poppedBuilds, 0);
    expect(find.text('instant'), findsNothing);
  });
}
