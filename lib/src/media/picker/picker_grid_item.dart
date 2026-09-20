import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/picker/picker_view_kind.dart';
import 'package:ux/src/media/picker/selection_context.dart';
import 'package:ux/src/media/picker/thumbnail_cache.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/gallery.dart';
import 'package:ux/src/media/compose/compose_entry.dart';
import 'package:ux/src/media/hidden_media_controller.dart';
import 'package:ux/src/media/touch.dart';
import 'package:ux/src/media/transition/gallery_source.dart';

/// Build-stable registry of mounted picker thumbnail hero sources.
///
/// `BuildContext.visitChildElements` is illegal while Flutter is updating a
/// subtree, and close/open hero lookups can happen during route builds. Cells
/// register their source as they mount, so the picker page can answer hero
/// lookups with a normal map read instead of walking the element tree.
class PickerSourceRegistry {
  final Map<_PickerSourceKey, GallerySource> _sources = {};

  /// Records [source] for the cell of [assetId] in [viewKind].
  void register(Object assetId, PickerViewKind viewKind, GallerySource source) {
    _sources[_PickerSourceKey(assetId, viewKind)] = source;
  }

  /// Forgets [source] when it is still the one recorded.
  void unregister(
    Object assetId,
    PickerViewKind viewKind,
    GallerySource source,
  ) {
    final key = _PickerSourceKey(assetId, viewKind);
    if (_sources[key] == source) _sources.remove(key);
  }

  /// The source of the mounted cell of [assetId] in [viewKind].
  GallerySource? sourceFor(Object assetId, PickerViewKind viewKind) =>
      _sources[_PickerSourceKey(assetId, viewKind)];

  /// Forgets every source.
  void clear() => _sources.clear();
}

class _PickerSourceKey {
  const _PickerSourceKey(this.assetId, this.viewKind);

  final Object assetId;
  final PickerViewKind viewKind;

  @override
  bool operator ==(Object other) =>
      other is _PickerSourceKey &&
      other.assetId == assetId &&
      other.viewKind == viewKind;

  @override
  int get hashCode => Object.hash(assetId, viewKind);
}

/// Single grid cell — thumbnail + selection ring + duration badge for
/// video. Telegram's `MediaPickerGridItem` shape: square aspect, ring
/// at top-right with the 1-based pick index, video duration at
/// bottom-left.
///
/// When the picker has a [ComposeEntry] for [asset] (because the user
/// edited it during this picker session), the thumbnail paints the
/// entry's `renderedPreview` instead of the gallery thumbnail —
/// telegram parity: edits are visible in the grid until the picker
/// pops.
class PickerGridItem extends StatelessWidget {
  /// Creates the cell of [asset].
  const PickerGridItem({
    super.key,
    required this.asset,
    required this.cellSizePx,
    required this.selection,
    required this.cache,
    required this.entriesById,
    required this.onTap,
    required this.viewKind,
    required this.sourceRegistry,
  });

  /// The asset shown.
  final XAsset asset;
  /// Thumbnail size requested, in physical pixels.
  final int cellSizePx;
  /// The picked assets, which number the ring.
  final SelectionContext selection;
  /// Where the thumbnail loads from.
  final ThumbnailCache cache;
  /// Compose entries by asset id; an edited asset shows its entry's preview.
  final Map<String, ComposeEntry> entriesById;
  /// Called on a tap of the cell's body.
  final ValueChanged<XAsset> onTap;

  /// Which view this cell lives in (`grid` or `strip`). The picker's
  /// `transitionSourceFor` closure consults `_displayMode` so the
  /// hero animation lands on whichever view is visible.
  final PickerViewKind viewKind;
  /// Where the cell records its transition source.
  final PickerSourceRegistry sourceRegistry;

  @override
  Widget build(BuildContext context) {
    return Touch(
      fade: 0.7,
      onPress: () => onTap(asset),
      child: ListenableBuilder(
        listenable: selection,
        builder: (context, _) {
          final index = selection.indexOf(asset);
          final selected = index != null;
          return Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: colors.fill,
                child: _Thumbnail(
                  assetId: asset.id,
                  sizePx: cellSizePx,
                  cache: cache,
                  entry: entriesById[asset.id],
                  viewKind: viewKind,
                  sourceRegistry: sourceRegistry,
                ),
              ),
              if (asset.kind == XAssetKind.video) _DurationBadge(asset: asset),
              if (selected)
                Positioned.fill(
                  child: ColoredBox(
                    color: colors.brand.withValues(alpha: 0.20),
                  ),
                ),
              Positioned(
                top: 0,
                right: 0,
                child: Touch(
                  // Larger hit target than the visible 24px ring so
                  // selection toggle is thumb-reachable; the body tap
                  // (outer Touch) routes to compose for selected
                  // assets so the ring is the only way to deselect.
                  padding: const EdgeInsets.all(6),
                  onPress: () => selection.toggle(asset),
                  child: _SelectionRing(
                    assetId: asset.id,
                    index: index,
                    springPlayed: cache.ringSpringPlayed,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Thumbnail extends StatefulWidget {
  const _Thumbnail({
    required this.assetId,
    required this.sizePx,
    required this.cache,
    required this.viewKind,
    required this.sourceRegistry,
    this.entry,
  });

  final String assetId;
  final int sizePx;
  final ThumbnailCache cache;

  /// Optional per-asset compose state. When [ComposeEntry.renderedPreview]
  /// is non-null, the cell paints the edited preview instead of the
  /// system thumbnail. Subscribed so post-edit preview rasterisations
  /// repaint the cell automatically.
  final ComposeEntry? entry;

  /// Which view this cell lives in. Combined with [assetId] in the picker
  /// source registry so grid and strip cells for the same asset resolve
  /// independently.
  final PickerViewKind viewKind;
  final PickerSourceRegistry sourceRegistry;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  XAssetThumbnail? _thumb;

  /// Wraps the visible thumbnail in a [RepaintBoundary] so the compose
  /// open / close hero-flight can capture the current pixels (edited
  /// preview or raw asset thumbnail) and resolve the picker cell's
  /// screen rect via [RepaintBoundaryGallerySource].
  final GlobalKey _boundaryKey = GlobalKey();

  /// Live transition source over this cell's `RepaintBoundary`.
  late final GallerySource gallerySource = RepaintBoundaryGallerySource(
    _boundaryKey,
    borderRadius: widget.viewKind == PickerViewKind.strip
        ? BorderRadius.circular(radius.sm)
        : BorderRadius.zero,
  );

  @override
  void initState() {
    super.initState();
    _registerSource();
    _load();
  }

  @override
  void didUpdateWidget(_Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId ||
        oldWidget.viewKind != widget.viewKind ||
        oldWidget.sourceRegistry != widget.sourceRegistry) {
      oldWidget.sourceRegistry.unregister(
        oldWidget.assetId,
        oldWidget.viewKind,
        gallerySource,
      );
      _registerSource();
    }
    if (oldWidget.assetId != widget.assetId ||
        oldWidget.sizePx != widget.sizePx) {
      _thumb = null;
      _load();
    }
  }

  @override
  void dispose() {
    widget.sourceRegistry.unregister(
      widget.assetId,
      widget.viewKind,
      gallerySource,
    );
    super.dispose();
  }

  void _registerSource() {
    widget.sourceRegistry.register(
      widget.assetId,
      widget.viewKind,
      gallerySource,
    );
  }

  Future<void> _load() async {
    final cached = widget.cache.peek(widget.assetId, widget.sizePx);
    if (cached != null) {
      setState(() => _thumb = cached);
      return;
    }
    try {
      final thumb = await widget.cache.load(
        widget.assetId,
        sizePx: widget.sizePx,
      );
      if (!mounted) return;
      setState(() => _thumb = thumb);
    } catch (_) {
      // Silently fail — the cell stays at the dark backdrop.
    }
  }

  @override
  Widget build(BuildContext context) {
    return HiddenMedia(
      ids: [widget.assetId],
      child: RepaintBoundary(key: _boundaryKey, child: _buildContent()),
    );
  }

  Widget _buildContent() {
    final entry = widget.entry;
    if (entry == null) return _buildFallback();
    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) {
        final preview = entry.renderedPreview;
        if (preview == null) return _buildFallback();
        return RawImage(image: preview, fit: BoxFit.cover);
      },
    );
  }

  Widget _buildFallback() {
    final t = _thumb;
    if (t == null) return const SizedBox.expand();
    return Image.memory(
      t.bytes,
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );
  }
}

class _DurationBadge extends StatelessWidget {
  const _DurationBadge({required this.asset});

  final XAsset asset;

  @override
  Widget build(BuildContext context) {
    final d = asset.duration;
    if (d == null) return const SizedBox.shrink();
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    final label = '$minutes:${seconds.toString().padLeft(2, '0')}';
    return Positioned(
      left: 6,
      bottom: 6,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0x99000000),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: colors.onMedia,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _SelectionRing extends StatefulWidget {
  const _SelectionRing({
    required this.assetId,
    required this.index,
    required this.springPlayed,
  });

  final String assetId;
  final int? index;

  /// Per-session set tracking which assets have already played their
  /// scale-in spring; the ring consults it on first mount to skip the
  /// animation when the tile is being remounted after a scroll-recycle.
  final Set<String> springPlayed;

  @override
  State<_SelectionRing> createState() => _SelectionRingState();
}

class _SelectionRingState extends State<_SelectionRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry;

  @override
  void initState() {
    super.initState();
    final alreadyPlayed = widget.springPlayed.contains(widget.assetId);
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
      value: alreadyPlayed ? 1.0 : 0.0,
    );
    if (!alreadyPlayed) {
      widget.springPlayed.add(widget.assetId);
      _entry.forward();
    }
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.index;
    final selected = index != null;
    return ScaleTransition(
      scale: Tween<double>(begin: 0.2, end: 1.0).animate(
        CurvedAnimation(parent: _entry, curve: Curves.easeOutBack),
      ),
      child: FadeTransition(
        opacity: _entry,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? colors.brand : const Color(0x55000000),
            border: Border.all(color: colors.onMedia, width: 1.5),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: selected
                ? Text(
                    '$index',
                    key: ValueKey<int>(index),
                    style: TextStyle(
                      color: colors.onBrand,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey<String>('empty')),
          ),
        ),
      ),
    );
  }
}
