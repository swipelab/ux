import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:ux/camera.dart';
import 'package:ux/gallery.dart';
import 'package:ux/log.dart';
import 'package:ux/src/media/camera/camera_page.dart';
import 'package:ux/src/media/camera/camera_session.dart';
import 'package:ux/src/media/camera/camera_thumb.dart';
import 'package:ux/src/media/compose/compose_entry.dart';
import 'package:ux/src/media/compose/compose_page.dart';
import 'package:ux/src/media/count_odometer.dart';
import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/host.dart';
import 'package:ux/src/media/picker/albums_screen.dart';
import 'package:ux/src/media/picker/picker_grid_item.dart';
import 'package:ux/src/media/picker/picker_grid_layout.dart';
import 'package:ux/src/media/picker/picker_permission_view.dart';
import 'package:ux/src/media/picker/picker_view_kind.dart';
import 'package:ux/src/media/picker/selected_strip.dart';
import 'package:ux/src/media/picker/selection_context.dart';
import 'package:ux/src/media/picker/thumbnail_cache.dart';
import 'package:ux/src/media/touch.dart';
import 'package:ux/src/media/transition/gallery_source.dart';
import 'package:ux/src/media/x_media.dart';
import 'package:ux/ux.dart';

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

/// A media-library sheet with a live camera cell and [maxSelection] picks.
///
/// The sheet and grid coordinate scrolling through [SheetController]. Gallery
/// edits remain picker-owned across editor cancellation. Captures are composed
/// independently of gallery selections; confirmation dismisses the picker.
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

  /// Restricts the library and camera output; null permits photos and videos.
  final XAssetKind? filter;

  /// Called by the editor before confirmation to provide send-transition targets.
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
  StreamSubscription<void>? _librarySub;
  ValueListenable<AppLifecycleState>? _lifecycle;
  AppLifecycleState? _lastLifecycle;
  int _photoRefresh = 0;
  int _cameraRefresh = 0;
  bool? _cameraPermission;
  CameraSession? _cameraSession;
  Future<void> _cameraRelease = Future.value();
  bool _routePending = false;
  bool _dismissing = false;
  bool get _closed => disposed || popped || _dismissing;
  bool get _hasPhotos =>
      _permission == XGalleryPermission.granted ||
      _permission == XGalleryPermission.limited;
  bool get _canPreviewCamera =>
      _cameraPermission == true && (_permission == null || _hasPhotos);

  DisplayMode _displayMode = DisplayMode.all;

  /// Whether the grid or the strip of picked assets shows.
  DisplayMode get displayMode => _displayMode;

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
  Future<ComposeEntry?> _entryFor(XAsset asset) async {
    final existing = _entriesById[asset.id];
    if (existing != null) return existing;
    final file = await XGallery.resolveFile(asset.id);
    if (_closed) return null;
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
    _librarySub = XGallery.libraryChanges.listen((_) => _refreshPhotos());
    _lifecycle = MediaHost.current.lifecycle;
    _lastLifecycle = _lifecycle!.value;
    _lifecycle!.addListener(_onLifecycle);
    _refreshAccess();
  }

  void _onLifecycle() {
    final next = _lifecycle!.value;
    final previous = _lastLifecycle;
    _lastLifecycle = next;
    if (next == AppLifecycleState.resumed && previous != next) {
      _refreshAccess();
    }
  }

  Future<void> _refreshAccess() =>
      Future.wait([_refreshPhotos(), _refreshCamera()]);

  void _safeNotify() {
    if (!_closed) notifyListeners();
  }

  Future<void> _refreshPhotos({bool request = false}) async {
    if (_closed) return;
    final revision = ++_photoRefresh;
    try {
      final permission = await (request
          ? XGallery.requestPermission()
          : XGallery.permission());
      if (_closed || revision != _photoRefresh) return;
      _permission = permission;
      unawaited(_reconcileCamera());
      if (!_hasPhotos) {
        _assets.clear();
        _albums = const [];
        _safeNotify();
        return;
      }
      _safeNotify();
      final (assets, albums) = await (
        XGallery.assets(
          albumId: _currentAlbum?.id,
          filter: filter,
          start: 0,
          end: 200,
        ),
        XGallery.albums(filter: filter),
      ).wait;
      if (_closed || revision != _photoRefresh) return;
      _assets
        ..clear()
        ..addAll(assets);
      _albums = albums;
      _safeNotify();
    } catch (error, stack) {
      Log.tag('picker')
          .w('photo refresh failed', error: error, stackTrace: stack);
    }
  }

  Future<void> _releaseCamera() {
    final session = _cameraSession;
    _cameraSession = null;
    if (session != null) {
      session.removeListener(_safeNotify);
      _cameraRelease = session.dispose();
    }
    return _cameraRelease;
  }

  Future<void> _refreshCamera({bool request = false}) async {
    if (_closed) return;
    final revision = ++_cameraRefresh;
    try {
      final granted = await (request
          ? XCameraController.requestCameraPermission()
          : XCameraController.cameraPermissionGranted());
      if (_closed || revision != _cameraRefresh) return;
      _cameraPermission = granted;
      await _reconcileCamera();
    } catch (error, stack) {
      Log.tag('picker')
          .w('camera refresh failed', error: error, stackTrace: stack);
    }
  }

  Future<void> _reconcileCamera() async {
    try {
      if (!_canPreviewCamera) {
        final releasing = _releaseCamera();
        _safeNotify();
        await releasing;
        return;
      }
      await _cameraRelease;
      if (_closed || !_canPreviewCamera) return;
      final session = _cameraSession ??= (CameraSession()
        ..addListener(_safeNotify));
      await session.initialize();
      _safeNotify();
    } catch (error, stack) {
      Log.tag('picker')
          .w('camera reconciliation failed', error: error, stackTrace: stack);
    }
  }

  /// Requests photo access and reloads the authorized library.
  Future<void> handleAllowAccess() => _refreshPhotos(request: true);

  /// Requests camera access, opening Settings when a prompt is unavailable.
  Future<void> handleCameraAccess() => _refreshCamera(request: true);

  /// Opens the system sheet that changes which photos the app may read.
  Future<void> handleManageLimited() => XGallery.presentLimitedLibraryPicker();

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
    if (_closed || picked == null) return;
    await selectAlbum(picked.id == 'recents' ? null : picked);
  }

  /// Switch to [album] (or `null` for Recents) and reload the grid.
  Future<void> selectAlbum(XAlbum? album) async {
    if (_closed || album?.id == _currentAlbum?.id) return;
    _currentAlbum = album;
    await _refreshPhotos();
  }

  @override
  void dispose() {
    _lifecycle?.removeListener(_onLifecycle);
    _lifecycle = null;
    _librarySub?.cancel();
    _releaseCamera();
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
    if (_closed) return;
    _dismissing = true;
    await sheetController.animateDismiss();
    if (!disposed && !popped) pop(result);
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
    if (_closed || _routePending) return;
    _routePending = true;
    try {
      final entries = <ComposeEntry>[];
      for (final asset in assets) {
        final entry = await _entryFor(asset);
        if (_closed || entry == null) return;
        entries.add(entry);
      }
      final results = await ComposePage.borrowed(
        entries: entries,
        initialSourceRect: transitionSourceFor(assets.first.id)?.currentRect,
        transitionSourceFor: transitionSourceFor,
        onSubmit: onSubmit,
        purpose: composePurpose,
      ).push();
      if (!_closed && results != null) await _animatedPop(results);
    } finally {
      _routePending = false;
    }
  }

  /// Captures with the grid's session and composes independently of selection.
  Future<void> handleCameraTap() async {
    final session = _cameraSession;
    if (_closed || _routePending || session?.value == null) return;
    _routePending = true;
    try {
      final media = await CameraPage(session: session, filter: filter).push();
      if (_closed || media == null) return;
      final results = await ComposePage(
        assets: [media],
        onSubmit: onSubmit,
        purpose: composePurpose,
      ).push();
      if (!_closed && results != null) await _animatedPop(results);
    } finally {
      _routePending = false;
    }
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
              title: _permission == null || _hasPhotos
                  ? _currentAlbum?.name ?? 'Recents'
                  : null,
              onCancel: handleCancel,
              onTitleTap: _albums.length > 1 ? openAlbums : null,
              toggle: _hasPhotos && _toggleVisible
                  ? _SelectedToggle(
                      count: selection.count,
                      active: _displayMode == DisplayMode.selected,
                      onTap: toggleDisplayMode,
                    )
                  : null,
            ),
            Expanded(child: _buildBody()),
            if (_hasPhotos)
              ListenableBuilder(
                listenable: selection,
                builder: (context, _) =>
                    _SendFooter(count: selection.count, onSend: handleSend),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final permission = _permission;
    if (permission != null && !_hasPhotos) {
      return PickerPermissionPlaceholder(
        state: permission,
        onAllow: handleAllowAccess,
        onSettings: XGallery.openSettings,
      );
    }
    return Stack(
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
              camera: _cameraSession?.value == null ? null : _cameraSession,
              onCamera: handleCameraTap,
              permission: _permission,
              onManage: handleManageLimited,
              cameraDenied: _cameraPermission == false,
              onCameraAccess: handleCameraAccess,
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
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.onCancel,
    this.onTitleTap,
    this.toggle,
  });

  final String? title;
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
    final title = this.title;
    final tap = onTitleTap;
    final titleStyle = TextStyle(
      color: colors.textPrimary,
      fontSize: 17,
      fontWeight: FontWeight.w600,
    );
    final Widget titleContent = title == null
        ? const SizedBox.shrink()
        : tap == null
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
    required this.camera,
    required this.onCamera,
    required this.permission,
    required this.onManage,
    required this.cameraDenied,
    required this.onCameraAccess,
  });

  final List<XAsset> assets;
  final SelectionContext selection;
  final ThumbnailCache cache;
  final SheetController sheetController;
  final Map<String, ComposeEntry> entriesById;
  final PickerSourceRegistry sourceRegistry;
  final ValueChanged<XAsset> onTap;
  final PickerViewKind viewKind;
  final CameraSession? camera;
  final VoidCallback onCamera;
  final XGalleryPermission? permission;
  final VoidCallback onManage;
  final bool cameraDenied;
  final VoidCallback onCameraAccess;

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

    final camera = widget.camera;
    return CustomScrollView(
      controller: _scroll,
      physics: widget.sheetController.physics,
      slivers: [
        if (widget.permission == XGalleryPermission.limited)
          SliverToBoxAdapter(
            child: PickerLimitedBanner(onManage: widget.onManage),
          ),
        if (widget.cameraDenied)
          SliverToBoxAdapter(
            child: PickerCameraBanner(onAllow: widget.onCameraAccess),
          ),
        SliverGrid(
          gridDelegate: PickerGridDelegate(
            columns: cols,
            hasCamera: camera != null,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            if (camera != null && index == 0) {
              return Touch(
                onPress: widget.onCamera,
                child: CameraThumb(
                  controller: camera,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(CupertinoIcons.camera, color: colors.onMedia),
                    ),
                  ),
                ),
              );
            }
            final asset = widget.assets[index - (camera == null ? 0 : 1)];
            return PickerGridItem(
              key: ValueKey(asset.id),
              asset: asset,
              cellSizePx: cellPx,
              selection: widget.selection,
              cache: widget.cache,
              entriesById: widget.entriesById,
              sourceRegistry: widget.sourceRegistry,
              onTap: widget.onTap,
              viewKind: widget.viewKind,
            );
          }, childCount: widget.assets.length + (camera == null ? 0 : 1)),
        ),
      ],
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
      padding: EdgeInsets.symmetric(horizontal: space.md, vertical: space.sm),
      child: Row(
        children: [
          Text(
            '$count selected',
            style: TextStyle(color: colors.textPrimary, fontSize: 14),
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
