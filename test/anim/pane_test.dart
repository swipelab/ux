import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/anim/pane.dart';

/// A pane that stacks slots `0` to `count - 1` top to bottom, each built by
/// [builder].
class _ColumnPane extends Pane {
  _ColumnPane(this.builder);

  final Widget Function(int slot) builder;

  int count = 1;

  final Map<Object?, Offset> _offsets = {};

  @override
  void setupParentData(RenderObject child, Object? slot) {}

  @override
  void performLayout() {
    var top = 0.0;
    for (var slot = 0; slot < count; slot++) {
      final child = invokeLayoutUpsert(slot)!
        ..layout(constraints.loosen(), parentUsesSize: true);
      _offsets[slot] = Offset(0, top);
      top += child.size.height;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    renderBoxes.forEach(
      (slot, child) => context.paintChild(child, offset + _offsets[slot]!),
    );
  }

  @override
  Widget itemBuilder(BuildContext context, Object? slot) =>
      builder(slot as int);
}

void main() {
  testWidgets('a pane laid out in a post-frame callback builds its new slot '
      'and leaves a dirty widget outside it, under the same LayoutBuilder, '
      'to the next frame', (tester) async {
    final pane = _ColumnPane((slot) => Text('slot $slot'));
    final outside = ValueNotifier(0);
    addTearDown(outside.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              ValueListenableBuilder<int>(
                valueListenable: outside,
                builder: (context, value, _) => Text('outside $value'),
              ),
              Expanded(child: PaneViewport(controller: pane)),
            ],
          ),
        ),
      ),
    );

    late bool slotBuilt;
    late bool outsideBuilt;
    tester.binding
      ..addPostFrameCallback((_) {
        outside.value = 1;
        pane.count = 2;
        pane.flushLayoutSync();
        slotBuilt = find.text('slot 1').evaluate().isNotEmpty;
        outsideBuilt = find.text('outside 1').evaluate().isNotEmpty;
      })
      ..scheduleFrame();
    await tester.pump();
    expect(slotBuilt, isTrue);
    expect(outsideBuilt, isFalse);

    await tester.pump();
    expect(find.text('outside 1'), findsOneWidget);
  });

  testWidgets("a pane's slot that marks itself dirty rebuilds on the next "
      'frame', (tester) async {
    final inside = ValueNotifier(0);
    addTearDown(inside.dispose);
    final pane = _ColumnPane(
      (slot) => ValueListenableBuilder<int>(
        valueListenable: inside,
        builder: (context, value, _) => Text('slot $slot: $value'),
      ),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PaneViewport(controller: pane),
      ),
    );

    inside.value = 1;
    await tester.pump();
    expect(find.text('slot 0: 1'), findsOneWidget);
  });
}
