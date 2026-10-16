import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

class _Screen with Screen<void> {
  _Screen(this.child);

  final Widget child;

  @override
  Widget buildPresenter(BuildContext context) => child;
}

/// A button labelled [label] that logs its taps, and its State's creation and
/// disposal under the label it was created with, to [events].
class _Tile extends StatefulWidget {
  const _Tile(this.label, this.events);

  final String label;
  final List<String> events;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  late final _label = widget.label;

  @override
  void initState() {
    super.initState();
    widget.events.add('init $_label');
  }

  @override
  void dispose() {
    widget.events.add('dispose $_label');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      onPressed: () => widget.events.add('tap ${widget.label}'),
      child: Text(widget.label),
    ),
  );
}

void main() {
  testWidgets('an XApp over another router shows its screens in place of the '
      'old router\'s, which take no State over', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(
      XApp(router: XRouter(home: _Screen(_Tile('A', events)))),
    );
    await tester.pumpWidget(
      XApp(router: XRouter(home: _Screen(_Tile('B', events)))),
    );
    await tester.tap(find.text('B'));
    expect(events, ['init A', 'init B', 'dispose A', 'tap B']);
  });

  testWidgets('an XApp keeps its router\'s screens where the widgets above its '
      'overlay change shape between platforms', (tester) async {
    final events = <String>[];
    final router = XRouter(home: _Screen(_Tile('A', events)));
    await tester.pumpWidget(XApp(router: router));
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(XApp(router: router));
    await tester.tap(find.text('A'));
    debugDefaultTargetPlatformOverride = null;
    expect(events, ['init A', 'tap A']);
  });
}
