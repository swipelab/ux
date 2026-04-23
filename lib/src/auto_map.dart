/// Insertion-ordered collection with O(1) lookup by key **and** by index.
///
/// Backed by a `List<V>` + `Map<K, int>` kept consistent by the four mutation
/// methods. Both fields are private; external callers cannot break the
/// invariant `_indexByKey[k] == i ⇔ _keyOf(_list[i]) == k`.
///
/// **Contract**: the key returned by `keyOf(value)` must not change after the
/// value is added. Mutating the derived key on a stored value silently
/// desynchronizes the index from the data.
///
/// ```dart
/// final groups = AutoMap<int, Group>((g) => g.gid);
/// groups.add(Group(gid: 1, name: 'a'));
/// groups[1];              // O(1) key lookup
/// groups.elementAt(0);    // O(1) indexed access
/// ```
class AutoMap<K, V> extends Iterable<V> {
  /// Creates an empty map. [keyOf] derives the key for each stored value;
  /// its return value must be stable for the lifetime of the entry.
  AutoMap(this._keyOf);

  final K Function(V) _keyOf;
  final List<V> _list = [];
  final Map<K, int> _indexByKey = {};

  @override
  Iterator<V> get iterator => _list.iterator;

  @override
  int get length => _list.length;

  @override
  bool get isEmpty => _list.isEmpty;

  /// O(1). Overrides Iterable.elementAt (which would walk to index).
  @override
  V elementAt(int index) => _list[index];

  /// O(1). Overrides Iterable.last (which would walk to end).
  @override
  V get last => _list.last;

  /// O(1) key lookup. Returns null if absent.
  V? operator [](K key) {
    final i = _indexByKey[key];
    return i == null ? null : _list[i];
  }

  /// True if a value is stored under [key].
  bool containsKey(K key) => _indexByKey.containsKey(key);

  /// Keys in insertion order.
  Iterable<K> get keys => _indexByKey.keys;

  /// O(1). Replaces in place if the key already exists (position preserved),
  /// otherwise appends.
  void add(V value) {
    final k = _keyOf(value);
    final i = _indexByKey[k];
    if (i != null) {
      _list[i] = value;
    } else {
      _indexByKey[k] = _list.length;
      _list.add(value);
    }
  }

  /// O(n). Order-preserving: entries after the removed position shift down.
  /// Returns the removed value, or null if [key] was not present.
  V? remove(K key) {
    final i = _indexByKey.remove(key);
    if (i == null) return null;
    final removed = _list.removeAt(i);
    _indexByKey.updateAll((_, v) => v > i ? v - 1 : v);
    return removed;
  }

  /// Adds each item. Use `..clear()..addAll(xs)` for replace-all semantics.
  void addAll(Iterable<V> items) {
    for (final v in items) {
      add(v);
    }
  }

  /// Removes all entries.
  void clear() {
    _list.clear();
    _indexByKey.clear();
  }
}
