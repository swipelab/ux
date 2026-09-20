import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/picker/picker_grid_item.dart';
import 'package:ux/src/media/picker/picker_view_kind.dart';
import 'package:ux/src/media/picker/selection_context.dart';
import 'package:ux/src/media/picker/thumbnail_cache.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/src/media/compose/compose_entry.dart';
import 'package:ux/ux.dart';
import 'package:ux/gallery.dart';

/// Insert/remove animation for strip tiles.
const Duration kStripItemTransition = Duration(milliseconds: 200);

/// Logical-pixel size of each strip tile.
const double kSelectedStripTileSize = 96.0;

/// Horizontal carousel rendered when `DisplayMode.selected`. v1: a
/// simple thumbnail strip — telegram-iOS's `MediaPickerSelectedListNode`
/// wallpapered bubble-preview parity is post-v1, gated on banlu's
/// bubble system catching up.
///
/// Tiles reuse `PickerGridItem` so the selection ring + duration badge
/// render identically to the grid; tap-on-ring removes the item from
/// the strip with a fade + horizontal-collapse animation. Removing the
/// last item bubbles up via `SelectionContext`'s notify; the page's
/// `_clampDisplayMode` flips `DisplayMode` back to `.all`.
class SelectedStrip extends StatefulWidget {
  /// Creates the strip.
  const SelectedStrip({
    super.key,
    required this.selection,
    required this.cache,
    required this.sheetController,
    required this.entriesById,
    required this.sourceRegistry,
    required this.onTap,
  });

  /// The picked assets shown.
  final SelectionContext selection;
  /// Where thumbnails load from.
  final ThumbnailCache cache;
  /// The picker's sheet, which the strip's scroll coordinates with.
  final SheetController sheetController;
  /// Compose entries by asset id.
  final Map<String, ComposeEntry> entriesById;
  /// Where tiles record their transition sources.
  final PickerSourceRegistry sourceRegistry;
  /// Called on a tap of a tile's body.
  final ValueChanged<XAsset> onTap;

  @override
  State<SelectedStrip> createState() => _SelectedStripState();
}

class _SelectedStripState extends State<SelectedStrip> {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final ScrollController _scroll = ScrollController();

  /// Mirror of the selection list, mutated alongside AnimatedList's
  /// insert/remove calls so indices stay consistent across animation
  /// frames (telegram's `MediaPickerSelectedListNode` keeps an
  /// equivalent display copy).
  late List<XAsset> _items;

  @override
  void initState() {
    super.initState();
    _items = widget.selection.picked.toList();
    widget.selection.addListener(_syncItems);
  }

  @override
  void dispose() {
    widget.selection.removeListener(_syncItems);
    _scroll.dispose();
    super.dispose();
  }

  /// Diff `_items` against the latest `selection.picked` and translate
  /// the delta into AnimatedList insert/remove calls so the strip plays
  /// per-tile entry/exit animations rather than swapping in a fresh
  /// list on every notify.
  void _syncItems() {
    final next = widget.selection.picked.toList();
    final nextIds = {for (final a in next) a.id};
    final prevIds = {for (final a in _items) a.id};

    // Removals first so insertion indices below align with the final list.
    for (var i = _items.length - 1; i >= 0; i--) {
      if (!nextIds.contains(_items[i].id)) {
        final removed = _items.removeAt(i);
        _listKey.currentState?.removeItem(
          i,
          (context, anim) => _buildTile(removed, anim),
          duration: kStripItemTransition,
        );
      }
    }

    for (var i = 0; i < next.length; i++) {
      if (!prevIds.contains(next[i].id)) {
        _items.insert(i, next[i]);
        _listKey.currentState?.insertItem(i, duration: kStripItemTransition);
      }
    }
  }

  Widget _buildTile(XAsset asset, Animation<double> anim) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final tilePx = (kSelectedStripTileSize * dpr).round();
    return SizeTransition(
      axis: Axis.horizontal,
      sizeFactor: anim,
      child: FadeTransition(
        opacity: anim,
        child: Padding(
          // Right-edge gutter on every tile (instead of
          // `ListView.separated`'s in-between separators, which
          // `AnimatedList` doesn't support natively).
          padding: EdgeInsets.only(right: space.sm),
          child: AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius.sm),
              child: PickerGridItem(
                asset: asset,
                cellSizePx: tilePx,
                selection: widget.selection,
                cache: widget.cache,
                entriesById: widget.entriesById,
                sourceRegistry: widget.sourceRegistry,
                onTap: widget.onTap,
                viewKind: PickerViewKind.strip,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        height: kSelectedStripTileSize,
        child: AnimatedList(
          key: _listKey,
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: space.md),
          initialItemCount: _items.length,
          itemBuilder: (context, index, anim) =>
              _buildTile(_items[index], anim),
        ),
      ),
    );
  }
}
