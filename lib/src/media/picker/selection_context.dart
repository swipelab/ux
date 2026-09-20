import 'package:ux/ux.dart';
import 'package:ux/gallery.dart';

/// Picker body view mode — the grid (`all`) or a horizontal carousel
/// of just the picked items (`selected`). 1:1 with telegram-iOS's
/// `MediaPickerScreen.DisplayMode`.
enum DisplayMode {
  /// The grid of all assets.
  all,

  /// The strip of picked assets.
  selected,
}

/// Selection state for the picker. Mirrors telegram's
/// `TGMediaSelectionContext` — ordered list of picked assets, capped
/// at [limit], with check-mark indices that follow the pick order
/// (1-based to match the on-screen ring numerals).
class SelectionContext with Emitter {
  /// Creates an empty selection of at most [limit].
  SelectionContext({required this.limit});

  /// How many assets may be picked.
  final int limit;
  final List<XAsset> _picked = [];

  /// The picked assets in pick order.
  Iterable<XAsset> get picked => _picked;
  /// How many are picked.
  int get count => _picked.length;
  /// Whether nothing is picked.
  bool get isEmpty => _picked.isEmpty;
  /// Whether [limit] is reached.
  bool get isFull => _picked.length >= limit;

  /// Whether [a] is picked.
  bool isSelected(XAsset a) => _picked.any((x) => x.id == a.id);

  /// 1-based index for the on-screen ring numeral, or null if not selected.
  int? indexOf(XAsset a) {
    final i = _picked.indexWhere((x) => x.id == a.id);
    return i < 0 ? null : i + 1;
  }

  /// Toggle selection. Returns false when adding past the limit.
  bool toggle(XAsset a) {
    final i = _picked.indexWhere((x) => x.id == a.id);
    if (i >= 0) {
      _picked.removeAt(i);
      notifyListeners();
      return true;
    }
    if (_picked.length >= limit) return false;
    _picked.add(a);
    notifyListeners();
    return true;
  }
}
