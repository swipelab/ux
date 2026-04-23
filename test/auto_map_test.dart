import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

class _Item {
  _Item(this.id, this.name);
  final int id;
  final String name;
}

AutoMap<int, _Item> _map() => AutoMap<int, _Item>((i) => i.id);

void main() {
  group('AutoMap', () {
    test('empty on construction', () {
      final m = _map();
      expect(m, isEmpty);
      expect(m.length, 0);
      expect(m[1], isNull);
      expect(m.containsKey(1), isFalse);
    });

    test('add appends new entries in insertion order', () {
      final m = _map()
        ..add(_Item(3, 'c'))
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'));
      expect(m.map((e) => e.id).toList(), [3, 1, 2]);
      expect(m.elementAt(0).id, 3);
      expect(m.elementAt(1).id, 1);
      expect(m.elementAt(2).id, 2);
    });

    test('add on existing key replaces in place', () {
      final m = _map()
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'))
        ..add(_Item(3, 'c'));
      m.add(_Item(2, 'B-new'));
      expect(m.map((e) => e.name).toList(), ['a', 'B-new', 'c']);
      expect(m[2]!.name, 'B-new');
      expect(m.elementAt(1).name, 'B-new');
      expect(m.length, 3);
    });

    test('operator [] returns null for missing key', () {
      final m = _map()..add(_Item(1, 'a'));
      expect(m[1]!.name, 'a');
      expect(m[999], isNull);
    });

    test('containsKey agrees with []', () {
      final m = _map()..add(_Item(7, 'g'));
      expect(m.containsKey(7), isTrue);
      expect(m.containsKey(8), isFalse);
    });

    test('remove returns the removed value and shifts indices', () {
      final m = _map()
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'))
        ..add(_Item(3, 'c'))
        ..add(_Item(4, 'd'));
      final removed = m.remove(2);
      expect(removed, isNotNull);
      expect(removed!.id, 2);
      expect(removed.name, 'b');
      expect(m.map((e) => e.id).toList(), [1, 3, 4]);
      expect(m.elementAt(0).id, 1);
      expect(m.elementAt(1).id, 3);
      expect(m.elementAt(2).id, 4);
      expect(m[3]!.name, 'c');
      expect(m[4]!.name, 'd');
      expect(m[2], isNull);
    });

    test('remove on missing key returns null', () {
      final m = _map()..add(_Item(1, 'a'));
      expect(m.remove(999), isNull);
      expect(m.length, 1);
    });

    test('add after remove assigns correct index', () {
      final m = _map()
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'))
        ..add(_Item(3, 'c'));
      m.remove(2);
      m.add(_Item(4, 'd'));
      expect(m.map((e) => e.id).toList(), [1, 3, 4]);
      expect(m.elementAt(2).id, 4);
      expect(m[4]!.name, 'd');
    });

    test('clear + addAll replaces contents', () {
      final m = _map()
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'))
        ..clear()
        ..addAll([_Item(10, 'x'), _Item(20, 'y'), _Item(30, 'z')]);
      expect(m.map((e) => e.id).toList(), [10, 20, 30]);
      expect(m[1], isNull);
      expect(m[10]!.name, 'x');
      expect(m.elementAt(2).id, 30);
    });

    test('addAll merges, replacing entries in place on collision', () {
      final m = _map()
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'))
        ..add(_Item(3, 'c'));
      m.addAll([_Item(2, 'B-new'), _Item(4, 'd')]);
      expect(m.map((e) => '${e.id}:${e.name}').toList(),
          ['1:a', '2:B-new', '3:c', '4:d']);
      expect(m.length, 4);
    });

    test('addAll on empty behaves like bulk insert', () {
      final m = _map()..addAll([_Item(1, 'a'), _Item(2, 'b')]);
      expect(m.length, 2);
      expect(m.elementAt(0).id, 1);
      expect(m.elementAt(1).id, 2);
    });

    test('clear drops both structures', () {
      final m = _map()
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'));
      m.clear();
      expect(m, isEmpty);
      expect(m[1], isNull);
      expect(m.containsKey(2), isFalse);
      m.add(_Item(3, 'c'));
      expect(m.elementAt(0).id, 3);
    });

    test('elementAt throws RangeError for out-of-range index', () {
      final m = _map()..add(_Item(1, 'a'));
      expect(() => m.elementAt(5), throwsA(isA<RangeError>()));
    });

    test('iteration order matches insertion, even with in-place updates', () {
      final m = _map()
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'))
        ..add(_Item(3, 'c'));
      m.add(_Item(1, 'A'));
      m.add(_Item(3, 'C'));
      expect(m.map((e) => '${e.id}:${e.name}').toList(),
          ['1:A', '2:b', '3:C']);
    });

    test('elementAt is O(1) on large collections', () {
      final m = _map();
      for (var i = 0; i < 10000; i++) {
        m.add(_Item(i, 'n$i'));
      }
      expect(m.elementAt(0).id, 0);
      expect(m.elementAt(5000).id, 5000);
      expect(m.elementAt(9999).id, 9999);
      expect(m[9999]!.name, 'n9999');
    });

    test('keys returns keys in insertion order', () {
      final m = _map()
        ..add(_Item(3, 'c'))
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'));
      expect(m.keys.toList(), [3, 1, 2]);
      m.add(_Item(3, 'C-new'));
      expect(m.keys.toList(), [3, 1, 2],
          reason: 'in-place replace must not reorder keys');
      m.remove(1);
      expect(m.keys.toList(), [3, 2]);
    });

    test('last is O(1) and returns the last inserted value', () {
      final m = _map()
        ..add(_Item(1, 'a'))
        ..add(_Item(2, 'b'))
        ..add(_Item(3, 'c'));
      expect(m.last.id, 3);
      m.remove(3);
      expect(m.last.id, 2);
    });

    test('last throws StateError on empty', () {
      final m = _map();
      expect(() => m.last, throwsStateError);
    });
  });
}
