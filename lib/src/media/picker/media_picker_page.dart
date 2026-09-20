import 'dart:async';

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/picker/albums_screen.dart';
import 'package:ux/src/media/picker/picker_grid_item.dart';
import 'package:ux/src/media/picker/picker_permission_view.dart';
import 'package:ux/src/media/picker/picker_view_kind.dart';
import 'package:ux/src/media/picker/selected_strip.dart';
import 'package:ux/src/media/picker/selection_context.dart';
import 'package:ux/src/media/picker/thumbnail_cache.dart';
import 'package:flutter/cupertino.dart';
import 'package:ux/src/media/compose/compose_entry.dart';
import 'package:ux/src/media/compose/compose_page.dart';
import 'package:ux/src/media/count_odometer.dart';
import 'package:ux/src/media/touch.dart';
import 'package:ux/src/media/transition/gallery_source.dart';
import 'package:ux/src/media/x_media.dart';
import 'package:ux/ux.dart';
import 'package:ux/gallery.dart';

/// Cross-fade duration when switching between grid and selected strip.
/// Matches telegram's `updateDisplayMode` curve
/// (`MediaPickerScreen.swift:1257`).
const Duration kDisplayModeTransition = Duration(milliseconds: 250);

/// Pill toggle entry/exit (scale + alpha). Telegram uses transform
/// scale 0.01 → 1.0 + alpha on visibility flip.
const Duration kPillVisibilityTransition = Duration(milliseconds: 200);

/// Stable top-level transitionBuilder for the pill `AnimatedSwitcher`.
/// Hoisted out of `_TopBar.build` so a fresh closure isn't allocated on
/// every page rebuild — `AnimatedSwitcher.didUpdateWidget` treats a new
/// closure as a transitionBuilder change and re-runs
/// `_updateTransitionForEntry` for every entry, churning the child
/// subtree and racing state preservation.
Widget _pillVisibilityTransition(Widget child, Animation<double> anim) {
  return ScaleTransition(
    scale: anim,
    child: FadeTransition(opacity: anim, child: child),
  );
}

/// Banlu's full-screen media picker — replaces `image_picker`'s system
/// sheet. Faithful port of telegram-iOS's `MediaPickerScreen` (grid +
/// multi-select up to [maxSelection]).
///
/// Mounts as a half-sheet via [SheetScreen]: the page enters at
/// `sheetCollapsedExtent` of the viewport, drag-up expands it
/// fullscreen, drag-down past the threshold dismisses it. Scroll on
/// the inner grid coordinates with the sheet's pan via the screen's
/// [SheetController].
///
/// On send, pushes [ComposePage.borrowed] with the selected assets'
/// borrowed [ComposeEntry]s; if the user sends from compose, the
/// picker pops with the per-entry results. Cancel from compose
/// returns the user to the picker with edits intact. Cancel from the
/// picker itself pops null. Mirrors telegram's "editor on top of
/// gallery" stacking.
class MediaPickerPage
    with
        Screen<List<ComposeResult>?>,
        SheetScreen<List<ComposeResult>?>,
        Emitter {
  /// Creates the picker.
  MediaPickerPage({
    this.maxSelection = 10,
    this.filter,
    this.onSubmit,
    this.composePurpose = ComposePurpose.mediaMessage,
  });

  /// How many assets may be picked.
  final int maxSelection;

  /// Restrict the grid + albums to a single asset kind. `null` shows
  /// photos and videos (the default chat-attachment flow); avatar
  /// pickers pass [XAssetKind.image] to hide videos.
  final XAssetKind? filter;

  /// Compose-submit handler — forwarded into the pushed
  /// [ComposePage.borrowed]. The chat-side provider inserts the
  /// placeholder bubble(s) and returns their cids; compose uses
  /// those for the close hero destination.
  final ComposeSubmitCallback? onSubmit;

  /// Which compose surface to show after picking. Avatar flows reuse the
  /// image tools but suppress chat-only caption UI.
  final ComposePurpose composePurpose;

  /// The picked assets.
  late final SelectionContext selection = SelectionContext(limit: maxSelection)
    ..disposeBy(this)
    ..addListener(_onSelectionChanged);
  final ThumbnailCache _thumbnails = ThumbnailCache();

  /// Per-asset compose state, keyed by [XAsset.id]. Created lazily
  /// on first compose open for an asset and kept until the picker
  /// pops — re-tap on a selected asset reopens compose with the same
  /// entry so crop / draw / caption survive the round-trip.
  final Map<String, ComposeEntry> _entriesById = <String, ComposeEntry>{};
  final PickerSourceRegistry _sourceRegistry = PickerSourceRegistry();

  final List<XAsset> _assets = <XAsset>[];
  XGalleryPermission? _permission;
  bool _loading = true;
  StreamSubscription<void>? _librarySub;

  DisplayMode _displayMode = DisplayMode.all;
  /// Whether the grid or the strip of picked assets shows.
  DisplayMode get displayMode => _displayMode;

  /// Mirrors `MediaPickerScreenImpl.isDismissing` in telegram-iOS
  /// [MediaPickerScreen.swift:2004](../../../../projects/telegram-ios/submodules/MediaPickerUI/Sources/MediaPickerScreen.swift#L2004),
  /// set at `sendSelected`'s outer entry (line 2293). Reset 1.5s later
  /// via [_isDismissingReset] (a `Chrono` so it pauses while the app is
  /// backgrounded and stays inert in widget tests where the binding
  /// lifecycle isn't `resumed`).
  bool _isDismissing = false;
  Chrono? _isDismissingReset;

  /// Toggle pill is hidden in single-select mode (1:1 with telegram —
  /// `MediaPickerScreen.swift:2628` only adds it when multiselect is on)
  /// and when nothing has been picked yet.
  bool get _toggleVisible => maxSelection > 1 && selection.count > 0;

  /// Single notify hook for selection changes: flip the body back to
  /// `.all` when the strip empties out, and — in single-pick mode —
  /// open compose immediately on the first tap so avatar-style flows
  /// don't need a Send confirmation tap.
  void _onSelectionChanged() {
    if (_displayMode == DisplayMode.selected && selection.isEmpty) {
      _displayMode = DisplayMode.all;
    }
    notifyListeners();
    if (maxSelection == 1 && selection.count == 1) {
      handleSend();
    }
  }

  /// Get-or-create the [ComposeEntry] for [asset]. Resolves the
  /// asset's file the first time and caches the entry; subsequent
  /// calls return the same instance so re-opening compose carries
  /// crop / draw / caption state across.
  Future<ComposeEntry> _entryFor(XAsset asset) async {
    final existing = _entriesById[asset.id];
    if (existing != null) return existing;
    final file = await XGallery.resolveFile(asset.id);
    final media = switch (asset.kind) {
      XAssetKind.image => ImageMedia(file: file),
      XAssetKind.video => VideoMedia(file: file),
    };
    return _entriesById.putIfAbsent(asset.id, () {
      final entry = ComposeEntry(
        input: media,
        sourceId: asset.id,
        contentSize: Size(asset.width.toDouble(), asset.height.toDouble()),
      );
      entry.subscribe(notifyListeners);
      return entry;
    });
  }

  /// Shows [mode]; the strip only while something is picked.
  void setDisplayMode(DisplayMode mode) {
    if (mode == _displayMode) return;
    if (mode == DisplayMode.selected && selection.isEmpty) return;
    _displayMode = mode;
    notifyListeners();
  }

  /// Switches between the grid and the strip.
  void toggleDisplayMode() => setDisplayMode(
    _displayMode == DisplayMode.all ? DisplayMode.selected : DisplayMode.all,
  );

  /// Currently active album. `null` means "Recents" (the virtual all-
  /// assets album).
  XAlbum? _currentAlbum;

  /// Cached album list — loaded lazily on first dropdown tap so the
  /// pushed `AlbumsScreen` mounts with data immediately. Subsequent
  /// taps reuse the cache.
  List<XAlbum> _albums = const [];

  @override
  Color get sheetBackgroundColor => colors.scaffold;

  @override
  Color get sheetBarrierColor => colors.scrim;

  @override
  void onPush() {
    super.onPush();
    _librarySub = XGallery.libraryChanges.listen((_) => _onLibraryChanged());
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final perm = await XGallery.permission();
    _permission = perm;
    if (perm == XGalleryPermission.granted ||
        perm == XGalleryPermission.limited) {
      await Future.wait([_loadAssetsForCurrentAlbum(), _loadAlbums()]);
    }
    _loading = false;
    notifyListeners();
  }

  /// Reactive reload triggered by the native `photoLibraryDidChange`
  /// observer — covers MANAGE add/remove, Photos.app edits, and
  /// Settings flips with one path. Fires only when we actually have
  /// access to fetch (granted / limited).
  Future<void> _onLibraryChanged() async {
    final perm = _permission;
    if (perm != XGalleryPermission.granted &&
        perm != XGalleryPermission.limited) {
      return;
    }
    await Future.wait([_loadAssetsForCurrentAlbum(), _loadAlbums()]);
    notifyListeners();
  }

  /// Triggered by the placeholder's `Allow Access` button when the
  /// system has never been asked — first-time prompt; subsequent
  /// denials require Settings.
  Future<void> handleAllowAccess() async {
    final perm = await XGallery.requestPermission();
    _permission = perm;
    if (perm == XGalleryPermission.granted ||
        perm == XGalleryPermission.limited) {
      await _loadAssetsForCurrentAlbum();
    }
    notifyListeners();
  }

  /// Opens the system sheet that changes which photos the app may read.
  Future<void> handleManageLimited() async {
    // Reload is driven by [_onLibraryChanged] via the
    // `XGallery.libraryChanges` stream, which fires after iOS
    // commits the new subset.
    await XGallery.presentLimitedLibraryPicker();
  }

  Future<void> _loadAssetsForCurrentAlbum() async {
    final assets = await XGallery.assets(
      albumId: _currentAlbum?.id,
      filter: filter,
      start: 0,
      end: 200,
    );
    _assets
      ..clear()
      ..addAll(assets);
  }

  Future<void> _loadAlbums() async {
    _albums = await XGallery.albums(filter: filter);
  }

  /// Push the album browser onto the sheet's nested stack
  /// (`host?.push(AlbumsScreen)`); on pop with a non-null result,
  /// switch the active album. Mirrors telegram's `MediaPickerScreen`
  /// → `MediaGroupsScreen` → pop-with-collection flow.
  Future<void> openAlbums() async {
    final picked = await host?.push(
      AlbumsScreen(
        albums: _albums,
        sheetController: sheetController,
        selectedId: _currentAlbum?.id,
      ),
    );
    // `picked == null` is genuine cancel (back arrow). The "Recents"
    // row pops the actual `recents` album so it round-trips through
    // `selectAlbum` and reloads the grid even when the current album
    // is something else.
    if (picked == null) return;
    await selectAlbum(picked.id == 'recents' ? null : picked);
  }

  /// Switch to [album] (or `null` for Recents) and reload the grid.
  Future<void> selectAlbum(XAlbum? album) async {
    if (album?.id == _currentAlbum?.id) return;
    _currentAlbum = album;
    _loading = true;
    notifyListeners();
    await _loadAssetsForCurrentAlbum();
    _loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDismissingReset?.cancel();
    _librarySub?.cancel();
    _thumbnails.clear();
    for (final e in _entriesById.values) {
      e.dispose();
    }
    _entriesById.clear();
    _sourceRegistry.clear();
    super.dispose();
  }

  /// Animate the sheet offscreen, then pop. Required for the X
  /// button and post-compose-Send paths — programmatic pop doesn't
  /// trigger the [Sheet]'s slide-down on its own (that only fires
  /// for drag / backdrop dismiss, which the Sheet handles before
  /// calling its `onDismiss` callback).
  Future<void> _animatedPop(List<ComposeResult>? result) async {
    await sheetController.animateDismiss();
    pop(result);
  }

  /// Dismisses the sheet and pops without a result.
  Future<void> handleCancel() => _animatedPop(null);

  /// Tap router for grid cells. Cell-body taps always open compose
  /// at that single asset — selection is reserved for the ring tap
  /// (top-right of each cell). Matches telegram parity: tapping a
  /// thumbnail opens the viewer; the ring is the only path to add /
  /// remove a multi-pick.
  Future<void> handleAssetTap(XAsset asset) async {
    await _openCompose([asset]);
  }

  /// Push [ComposePage.borrowed] with the picker-owned entries for the
  /// current selection. Pops the picker on Send (with compose's
  /// per-entry results); stays open on Cancel so edits are still
  /// visible in the grid.
  Future<void> handleSend() async {
    if (selection.isEmpty) return;
    await _openCompose(selection.picked.toList());
  }

  /// Tracks which view is currently in front. Telegram's equivalent
  /// is `selectionNode.alpha > 0.0` — we read [_displayMode] at call
  /// time, so the closure naturally follows the user's view toggles.
  PickerViewKind get _activeViewKind => _displayMode == DisplayMode.selected
      ? PickerViewKind.strip
      : PickerViewKind.grid;

  /// Central transition-source lookup. Compose's hero-flight calls
  /// this at dismiss time to find the cell to land on — the picker
  /// picks the right view based on its own current state, so the
  /// animation always targets what the user can see. Mirrors
  /// telegram-iOS's `MediaPickerScreen.transitionView(for:)`. Reads the
  /// mounted thumbnail registry; returns null when the matching cell is
  /// off-screen, picker-unmounted, or not in the active album.
  GallerySource? transitionSourceFor(Object assetId) =>
      _sourceRegistry.sourceFor(assetId, _activeViewKind);

  Future<void> _openCompose(List<XAsset> assets) async {
    if (_isDismissing) return;
    _isDismissing = true;
    _isDismissingReset?.cancel();
    _isDismissingReset = Chrono(const Duration(milliseconds: 1500), () {
      _isDismissing = false;
    });
    final entries = <ComposeEntry>[];
    for (final a in assets) {
      entries.add(await _entryFor(a));
    }
    final results = await ComposePage.borrowed(
      entries: entries,
      initialSourceRect: transitionSourceFor(assets.first.id)?.currentRect,
      transitionSourceFor: transitionSourceFor,
      onSubmit: onSubmit,
      purpose: composePurpose,
    ).push();
    if (results == null) {
      // Cancel from compose — picker stays open with edits intact.
      return;
    }
    await _animatedPop(results);
  }

  @override
  Widget buildSheetBody(BuildContext context) {
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) => SafeArea(
        top: false,
        child: Column(
          children: [
            _TopBar(
              title: _currentAlbum?.name ?? 'Recents',
              onCancel: handleCancel,
              onTitleTap: _albums.length > 1 ? openAlbums : null,
              toggle: _toggleVisible
                  ? _SelectedToggle(
                      count: selection.count,
                      active: _displayMode == DisplayMode.selected,
                      onTap: toggleDisplayMode,
                    )
                  : null,
            ),
            Expanded(child: _buildBody()),
            ListenableBuilder(
              listenable: selection,
              builder: (context, _) => _SendFooter(
                count: selection.count,
                onSend: handleSend,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const SizedBox.expand();
    final perm = _permission;
    if (perm != XGalleryPermission.granted &&
        perm != XGalleryPermission.limited) {
      return PickerPermissionPlaceholder(
        state: perm,
        onAllow: handleAllowAccess,
        onSettings: XGallery.openSettings,
      );
    }
    // Both children stay mounted across the cross-fade so the grid
    // retains its scroll position when the user round-trips through
    // `.selected` mode.
    final body = Stack(
      fit: StackFit.expand,
      children: [
        AnimatedOpacity(
          opacity: _displayMode == DisplayMode.all ? 1.0 : 0.0,
          duration: kDisplayModeTransition,
          curve: Curves.easeInOut,
          child: IgnorePointer(
            ignoring: _displayMode != DisplayMode.all,
            child: _Grid(
              assets: _assets,
              selection: selection,
              cache: _thumbnails,
              sheetController: sheetController,
              entriesById: _entriesById,
              sourceRegistry: _sourceRegistry,
              onTap: handleAssetTap,
              viewKind: PickerViewKind.grid,
            ),
          ),
        ),
        AnimatedOpacity(
          opacity: _displayMode == DisplayMode.selected ? 1.0 : 0.0,
          duration: kDisplayModeTransition,
          curve: Curves.easeInOut,
          child: IgnorePointer(
            ignoring: _displayMode != DisplayMode.selected,
            child: SelectedStrip(
              selection: selection,
              cache: _thumbnails,
              sheetController: sheetController,
              entriesById: _entriesById,
              sourceRegistry: _sourceRegistry,
              onTap: handleAssetTap,
            ),
          ),
        ),
      ],
    );
    if (perm == XGalleryPermission.limited) {
      return Column(
        children: [
          PickerLimitedBanner(onManage: handleManageLimited),
          Expanded(child: body),
        ],
      );
    }
    return body;
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.onCancel,
    this.onTitleTap,
    this.toggle,
  });

  final String title;
  final VoidCallback onCancel;

  /// Null when there's ≤1 album to switch to — the title renders as
  /// plain text without the chevron / hit area, since opening an
  /// `AlbumsScreen` with only "Recents" in it is dead-end UX.
  final VoidCallback? onTitleTap;

  /// `DisplayMode` pill, when present (multi-select with at least one
  /// pick). Replaces the otherwise-empty 44px right slot.
  final Widget? toggle;

  @override
  Widget build(BuildContext context) {
    final tap = onTitleTap;
    final titleStyle = TextStyle(
      color: colors.textPrimary,
      fontSize: 17,
      fontWeight: FontWeight.w600,
    );
    final Widget titleContent = tap == null
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(title, style: titleStyle),
          )
        : Touch(
            onPress: tap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: titleStyle),
                  const SizedBox(width: 4),
                  Icon(
                    CupertinoIcons.chevron_down,
                    color: colors.textPrimary,
                    size: 14,
                  ),
                ],
              ),
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4, right: 8),
      child: Row(
        children: [
          Touch(
            onPress: onCancel,
            child: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surface,
              ),
              child: Icon(
                CupertinoIcons.xmark,
                color: colors.textPrimary,
                size: 18,
              ),
            ),
          ),
          const Spacer(),
          titleContent,
          const Spacer(),
          SizedBox(
            height: 44,
            child: Center(
              child: AnimatedSwitcher(
                duration: kPillVisibilityTransition,
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: _pillVisibilityTransition,
                child: toggle ?? const SizedBox(width: 44),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Brand-fill pill button mirroring telegram-iOS's `SelectedButtonNode`
/// (`MediaPickerScreen.swift:4169`). Tap toggles between
/// `DisplayMode.all` and `DisplayMode.selected`.
class _SelectedToggle extends StatelessWidget {
  const _SelectedToggle({
    required this.count,
    required this.active,
    required this.onTap,
  });

  final int count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = colors.onBrand;
    final textStyle = TextStyle(
      color: fg,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Touch(
      fade: 0.7,
      onPress: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: colors.brand,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.check_mark, color: fg, size: 14),
            const SizedBox(width: 4),
            CountOdometer(count: count, style: textStyle),
          ],
        ),
      ),
    );
  }
}

class _Grid extends StatefulWidget {
  const _Grid({
    required this.assets,
    required this.selection,
    required this.cache,
    required this.sheetController,
    required this.entriesById,
    required this.sourceRegistry,
    required this.onTap,
    required this.viewKind,
  });

  final List<XAsset> assets;
  final SelectionContext selection;
  final ThumbnailCache cache;
  final SheetController sheetController;
  final Map<String, ComposeEntry> entriesById;
  final PickerSourceRegistry sourceRegistry;
  final ValueChanged<XAsset> onTap;
  final PickerViewKind viewKind;

  @override
  State<_Grid> createState() => _GridState();
}

class _GridState extends State<_Grid> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.sheetController.attach(_scroll);
  }

  @override
  void dispose() {
    widget.sheetController.detach(_scroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Screen-stable so thumbnail target px doesn't re-key on every
    // sheet-expand frame.
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    final cols = isLandscape ? 5 : 3;
    const spacing = 2.0;
    final cellLogical = (screenSize.width - (cols - 1) * spacing) / cols;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cellPx = (cellLogical * dpr).round();

    return GridView.builder(
      controller: _scroll,
      physics: widget.sheetController.physics,
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: 1,
      ),
      itemCount: widget.assets.length,
      itemBuilder: (context, index) => PickerGridItem(
        asset: widget.assets[index],
        cellSizePx: cellPx,
        selection: widget.selection,
        cache: widget.cache,
        entriesById: widget.entriesById,
        sourceRegistry: widget.sourceRegistry,
        onTap: widget.onTap,
        viewKind: widget.viewKind,
      ),
    );
  }
}

class _SendFooter extends StatelessWidget {
  const _SendFooter({required this.count, required this.onSend});

  final int count;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    return Container(
      color: colors.surface,
      padding: EdgeInsets.symmetric(
        horizontal: space.md,
        vertical: space.sm,
      ),
      child: Row(
        children: [
          Text(
            '$count selected',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
            ),
          ),
          const Spacer(),
          Touch(
            onPress: onSend,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: space.lg,
                vertical: space.sm,
              ),
              decoration: BoxDecoration(
                color: colors.brand,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Send',
                style: TextStyle(
                  color: colors.onBrand,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
