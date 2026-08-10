import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/anim/sheet.dart';

const double _screenHeight = 600.0;
const double _collapsedExtent = 0.6;
const double _halfSnapTop = _screenHeight * (1.0 - _collapsedExtent);
const double _expandedTop = 0.0;

double _sheetTop(WidgetTester tester) =>
    tester.getTopLeft(find.byType(SheetThumb)).dy;

Offset _inList(WidgetTester tester) => tester.getCenter(find.byType(ListView));

Offset _onThumb(WidgetTester tester) => tester.getCenter(find.byType(SheetThumb));

Future<void> _pumpSheet(
  WidgetTester tester, {
  required SheetController sheet,
  required ScrollController list,
  bool reverse = false,
  bool attach = true,
  int itemCount = 40,
  VoidCallback? onDismiss,
}) async {
  if (attach) sheet.attach(list);
  await tester.pumpWidget(
    MaterialApp(
      home: Sheet(
        controller: sheet,
        collapsedExtent: _collapsedExtent,
        onDismiss: onDismiss,
        child: ListView.builder(
          controller: list,
          physics: sheet.physics,
          reverse: reverse,
          itemCount: itemCount,
          itemBuilder: (context, index) =>
              SizedBox(height: 50, child: Text('item $index')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expandSheet(WidgetTester tester) async {
  await tester.dragFrom(_onThumb(tester), const Offset(0, -300));
  await tester.pumpAndSettle();
}

Future<void> _moveBy(WidgetTester tester, TestGesture gesture, double dy) async {
  await gesture.moveBy(Offset(0, dy));
  await tester.pump();
}

const Duration _frame = Duration(milliseconds: 16);

/// Pans from [start] through each `(velocity, frames)` phase — one pointer
/// move per frame, timestamped so the recognizer reads the phase velocity in
/// pixels per second — then lifts and settles.
Future<void> _panAndRelease(
  WidgetTester tester,
  Offset start,
  List<(double, int)> phases,
) async {
  final gesture = await tester.startGesture(start);
  var elapsed = Duration.zero;
  for (final (velocity, frames) in phases) {
    final dy = velocity * _frame.inMilliseconds / 1000.0;
    for (var i = 0; i < frames; i++) {
      elapsed += _frame;
      await gesture.moveBy(Offset(0, dy), timeStamp: elapsed);
      await tester.pump(_frame);
    }
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('Sheet drag arbitration', () {
    testWidgets(
      'half snap scrolls a scrolled forward list on a down-drag and holds the sheet',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);
        list.jumpTo(300);
        await tester.pump();

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 4; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, lessThan(280));
        expect(_sheetTop(tester), _halfSnapTop);

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'half snap scrolls a reversed list toward older content on a down-drag',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list, reverse: true);

        expect(list.offset, 0);

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 4; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, greaterThan(20));
        expect(_sheetTop(tester), _halfSnapTop);

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'half snap takes an upward reversal after a forward list scrolls down',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);
        list.jumpTo(300);
        await tester.pump();

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 4; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, lessThan(280));
        expect(_sheetTop(tester), _halfSnapTop);
        final offsetAfterDownDrag = list.offset;

        for (var i = 0; i < 3; i++) {
          await _moveBy(tester, gesture, -24);
        }

        expect(list.offset, offsetAfterDownDrag);
        expect(_sheetTop(tester), lessThan(_halfSnapTop - 20));

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'half snap takes an upward reversal after a reversed list scrolls down',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list, reverse: true);

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 4; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, greaterThan(20));
        expect(_sheetTop(tester), _halfSnapTop);
        final offsetAfterDownDrag = list.offset;

        for (var i = 0; i < 3; i++) {
          await _moveBy(tester, gesture, -24);
        }

        expect(list.offset, offsetAfterDownDrag);
        expect(_sheetTop(tester), lessThan(_halfSnapTop - 20));

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'expanded reversed list at the newest end scrolls toward older content on a down-drag',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list, reverse: true);
        await _expandSheet(tester);

        expect(_sheetTop(tester), _expandedTop);
        expect(list.offset, 0);

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 4; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, greaterThan(40));
        expect(_sheetTop(tester), _expandedTop);

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'half snap moves the sheet when the forward list sits at its down-drag edge',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 3; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, 0);
        expect(_sheetTop(tester), greaterThan(_halfSnapTop + 40));

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'half snap moves the sheet when the reversed list sits at its down-drag edge',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list, reverse: true);
        list.jumpTo(list.position.maxScrollExtent);
        await tester.pump();
        final atEdge = list.offset;

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 3; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, atEdge);
        expect(_sheetTop(tester), greaterThan(_halfSnapTop + 40));

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'the same gesture carries the drag to the sheet once the list reaches its edge',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);
        list.jumpTo(105);
        await tester.pump();

        final gesture = await tester.startGesture(_inList(tester));
        await _moveBy(tester, gesture, 24);
        for (var i = 0; i < 12 && list.offset > 20; i++) {
          await _moveBy(tester, gesture, 20);
          expect(_sheetTop(tester), _halfSnapTop);
        }

        final roomLeft = list.offset;
        expect(roomLeft, lessThanOrEqualTo(20));
        await _moveBy(tester, gesture, 20);

        expect(list.offset, 0);
        expect(_sheetTop(tester), closeTo(_halfSnapTop + 20 - roomLeft, 0.01));

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'up-drag at the half snap expands the sheet and leaves the overflowing list at rest',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);

        expect(list.offset, list.position.minScrollExtent);
        expect(list.position.maxScrollExtent, greaterThan(0));

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 3; i++) {
          await _moveBy(tester, gesture, -24);
        }

        expect(list.offset, 0);
        expect(_sheetTop(tester), lessThan(_halfSnapTop - 40));

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'a drag on the thumb moves the sheet while the list is away from its down-drag edge',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);
        await _expandSheet(tester);
        list.jumpTo(300);
        await tester.pump();

        final gesture = await tester.startGesture(_onThumb(tester));
        for (var i = 0; i < 3; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, 300);
        expect(_sheetTop(tester), greaterThan(_expandedTop + 40));

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'a second pointer landing on the thumb leaves the drag with the list',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);
        list.jumpTo(300);
        await tester.pump();

        final gesture = await tester.startGesture(_inList(tester), pointer: 1);
        for (var i = 0; i < 2; i++) {
          await _moveBy(tester, gesture, 24);
        }
        final offsetBeforeSecondPointer = list.offset;
        expect(offsetBeforeSecondPointer, lessThan(300));

        final second = await tester.startGesture(_onThumb(tester), pointer: 2);
        for (var i = 0; i < 3; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, lessThan(offsetBeforeSecondPointer));
        expect(_sheetTop(tester), _halfSnapTop);

        await second.up();
        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'the sheet keeps the gesture through a reversal at the half snap',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);
        list.jumpTo(300);
        await tester.pump();

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 5; i++) {
          await _moveBy(tester, gesture, -20);
        }
        expect(_sheetTop(tester), lessThan(_halfSnapTop));

        for (var i = 0; i < 12 && _sheetTop(tester) < _halfSnapTop; i++) {
          await _moveBy(tester, gesture, 20);
          expect(list.offset, 300);
        }
        expect(_sheetTop(tester), _halfSnapTop);

        await _moveBy(tester, gesture, 20);
        await _moveBy(tester, gesture, 20);

        expect(list.offset, lessThan(300));
        expect(_sheetTop(tester), _halfSnapTop);

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'the sheet keeps the gesture through a reversal at the expanded snap',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);
        await _expandSheet(tester);

        expect(list.offset, 0);

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 4; i++) {
          await _moveBy(tester, gesture, 20);
        }
        expect(_sheetTop(tester), greaterThan(_expandedTop));

        for (var i = 0; i < 12 && _sheetTop(tester) > _expandedTop; i++) {
          await _moveBy(tester, gesture, -20);
          expect(list.offset, 0);
        }
        expect(_sheetTop(tester), _expandedTop);

        await _moveBy(tester, gesture, -20);
        await _moveBy(tester, gesture, -20);

        expect(list.offset, greaterThan(0));
        expect(_sheetTop(tester), _expandedTop);

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('a list without overflow leaves the drag to the sheet',
        (tester) async {
      final sheet = SheetController();
      final list = ScrollController();
      addTearDown(list.dispose);
      await _pumpSheet(tester, sheet: sheet, list: list, itemCount: 2);

      expect(list.position.maxScrollExtent, 0);

      final gesture = await tester.startGesture(_inList(tester));
      for (var i = 0; i < 3; i++) {
        await _moveBy(tester, gesture, 24);
      }

      expect(list.offset, 0);
      expect(_sheetTop(tester), greaterThan(_halfSnapTop + 40));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('without an attached list the sheet takes the drag from the half snap',
        (tester) async {
      final sheet = SheetController();
      final list = ScrollController();
      addTearDown(list.dispose);
      await _pumpSheet(tester, sheet: sheet, list: list, attach: false);
      list.jumpTo(300);
      await tester.pump();

      final gesture = await tester.startGesture(_inList(tester));
      for (var i = 0; i < 3; i++) {
        await _moveBy(tester, gesture, 24);
      }

      expect(list.offset, 300);
      expect(_sheetTop(tester), greaterThan(_halfSnapTop + 40));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets(
      'without an attached list the sheet takes the drag from the expanded snap',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list, attach: false);
        await _expandSheet(tester);
        list.jumpTo(300);
        await tester.pump();

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 3; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, 300);
        expect(_sheetTop(tester), greaterThan(_expandedTop + 40));

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'expanded forward list scrolled away from its edge scrolls on a down-drag',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        await _pumpSheet(tester, sheet: sheet, list: list);
        await _expandSheet(tester);
        list.jumpTo(300);
        await tester.pump();

        final gesture = await tester.startGesture(_inList(tester));
        for (var i = 0; i < 4; i++) {
          await _moveBy(tester, gesture, 24);
        }

        expect(list.offset, lessThan(280));
        expect(_sheetTop(tester), _expandedTop);

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );
  });

  group('Sheet dismiss decision', () {
    testWidgets(
      'a drag past the dismiss line settles when the release moves upward',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        var dismissed = false;
        await _pumpSheet(
          tester,
          sheet: sheet,
          list: list,
          onDismiss: () => dismissed = true,
        );

        await _panAndRelease(tester, _onThumb(tester), const [
          (625.0, 12),
          (-250.0, 6),
        ]);

        expect(dismissed, isFalse);
        expect(_sheetTop(tester), _halfSnapTop);
      },
    );

    testWidgets(
      'a moderate downward fling short of the dismiss line dismisses',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        var dismissed = false;
        await _pumpSheet(
          tester,
          sheet: sheet,
          list: list,
          onDismiss: () => dismissed = true,
        );

        await _panAndRelease(tester, _onThumb(tester), const [(250.0, 10)]);

        expect(dismissed, isTrue);
      },
    );

    testWidgets('a release at rest past the dismiss line dismisses',
        (tester) async {
      final sheet = SheetController();
      final list = ScrollController();
      addTearDown(list.dispose);
      var dismissed = false;
      await _pumpSheet(
        tester,
        sheet: sheet,
        list: list,
        onDismiss: () => dismissed = true,
      );

      await _panAndRelease(tester, _onThumb(tester), const [
        (500.0, 10),
        (0.0, 8),
      ]);

      expect(dismissed, isTrue);
    });

    testWidgets(
      'a fast fling from expanded with the list at its edge dismisses',
      (tester) async {
        final sheet = SheetController();
        final list = ScrollController();
        addTearDown(list.dispose);
        var dismissed = false;
        await _pumpSheet(
          tester,
          sheet: sheet,
          list: list,
          onDismiss: () => dismissed = true,
        );
        await _expandSheet(tester);

        expect(list.offset, 0);

        await _panAndRelease(tester, _inList(tester), const [(2000.0, 8)]);

        expect(dismissed, isTrue);
      },
    );

    testWidgets('a fling on a list with room scrolls and never dismisses',
        (tester) async {
      final sheet = SheetController();
      final list = ScrollController();
      addTearDown(list.dispose);
      var dismissed = false;
      await _pumpSheet(
        tester,
        sheet: sheet,
        list: list,
        onDismiss: () => dismissed = true,
      );
      list.jumpTo(300);
      await tester.pump();

      await _panAndRelease(tester, _inList(tester), const [(750.0, 8)]);

      expect(dismissed, isFalse);
      expect(_sheetTop(tester), _halfSnapTop);
      expect(list.offset, lessThan(300));
    });
  });
}
