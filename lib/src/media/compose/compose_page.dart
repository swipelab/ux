import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/timing.dart';
import 'package:ux/src/media/compose/video_scrubber.dart';
import 'package:ux/src/media/x_media.dart';
import 'package:ux/src/media/compose/compose_constants.dart';
import 'package:ux/src/media/compose/compose_entry.dart';
import 'package:ux/src/media/dismiss_carrier.dart';
import 'package:ux/src/media/hidden_media_controller.dart';
import 'package:ux/src/media/transition/gallery_source.dart';
import 'package:ux/src/media/transition/gallery_transition.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:ux/src/media/host.dart';
import 'package:ux/src/media/media_commands_bar.dart';
import 'package:ux/src/media/touch.dart';
import 'package:ux/src/media/video_edit_values.dart';
import 'package:ux/ux.dart';

/// One slide's worth of submit output. Per-entry caption + a
/// reference to the picker's original media + (for edited entries)
/// the in-memory composited `ui.Image`. The chat-side dispatcher
/// (`chat_page._sendComposeResults`) feeds the composedImage into
/// `bloc.sendMediaMessage(OutgoingImageFromComposite(...))` so the
/// message is inserted into the stream before the PNG encode + upload
/// run — telegram's `enqueueMessages(mediaReference:)` parity.
///
/// Reply is page-level and stamped by the caller after `ComposePage`
/// pops — it does NOT live here because reply state belongs to the
/// chat composer, not the compose surface (telegram model).
class ComposeResult {
  /// Creates the result of one entry.
  const ComposeResult({
    required this.source,
    required this.composedImage,
    this.caption,
    this.imageBytes,
    this.videoEdit,
  });

  /// Original picker media — used as the upload source when no
  /// edits were applied, and as the fallback for bookmarks / file
  /// metadata.
  final XMedia source;

  /// In-memory composited image for edited entries; null when
  /// nothing was edited and [source] should be uploaded as-is.
  final ui.Image? composedImage;

  /// What [MediaHost.caption] read from the entry's caption controller on
  /// submit; absent when it read none or the page takes none.
  final Object? caption;

  /// Final visual bytes for flows that need to consume compose output
  /// after the owning entry has been disposed, such as avatars. Encoded
  /// after the page pops, so the caller shows progress where the image
  /// lands. A failure is delivered only to listeners.
  final Future<Uint8List>? imageBytes;

  /// Trim / mute values for video entries; baked into the upload by
  /// `OutgoingVideoFromFile` at send time. Null for images or
  /// untouched videos.
  final VideoEditValues? videoEdit;

  /// The final image as bytes: [imageBytes], else [composedImage] as PNG, else [source]'s file.
  Future<Uint8List> resolveImageBytes() async {
    final resolved = imageBytes;
    if (resolved != null) return resolved;
    final image = composedImage;
    if (image == null) return source.file.readAsBytes();
    return _png(image);
  }
}

Future<Uint8List> _png(ui.Image image) async {
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List(
    byteData.offsetInBytes,
    byteData.lengthInBytes,
  );
}

/// [input]'s final image as PNG bytes with its longest edge at most
/// [maxExtent]; disposes [image]. A video resolves to its file.
Future<Uint8List> _avatarBytes(
  XMedia input,
  ui.Image? image,
  int? maxExtent,
) async {
  if (input is! ImageMedia) return input.file.readAsBytes();
  if (image == null) {
    throw FormatException('The image cannot be decoded', input.file.path);
  }
  try {
    final longest = math.max(image.width, image.height);
    if (maxExtent == null || longest <= maxExtent) return await _png(image);
    final scale = maxExtent / longest;
    final width = math.max(1, (image.width * scale).round());
    final height = math.max(1, (image.height * scale).round());
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      Offset.zero & Size(width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final scaled = await picture.toImage(width, height);
    picture.dispose();
    try {
      return await _png(scaled);
    } finally {
      scaled.dispose();
    }
  } finally {
    image.dispose();
  }
}

/// What the composed media is for.
enum ComposePurpose {
  /// A message: the page takes a caption.
  mediaMessage,

  /// A profile picture: no caption, and results carry their bytes.
  avatar,
}

/// Per-result handle returned by [ComposeSubmitCallback]: the
/// placeholder bubble's `clientMessageId` plus a closure that resolves
/// the chat bubble's transition source for that cid. The closure
/// resolves lazily against the chat's current widget tree, so it
/// returns a live source on any frame after the placeholder has been
/// built.
class ChatSendResult {
  /// Creates the handle.
  const ChatSendResult({required this.cids, required this.sourceForCid});

  /// Client message ids of the placeholder bubbles, one per result.
  final List<String> cids;

  /// Finds the bubble of a cid to fly the close transition to.
  final GallerySource? Function(String cid) sourceForCid;
}

/// Compose-side submit callback. The caller (`chat_page`) provides
/// this so compose can pre-insert the chat bubble(s) **before** it
/// pops — mirrors telegram's `completion(results, finishedCallback)`
/// pattern from `MediaEditorScreen.swift:7664`. Returns the per-result
/// cids + bubble-source finders so compose can target the close hero
/// at the just-mounted bubbles without consulting any global registry.
typedef ComposeSubmitCallback = Future<ChatSendResult> Function(
  List<ComposeResult>,
);

/// Folded single + multi compose page. Accepts a list of `XMedia`
/// (1..N); single-asset callers wrap with `[m]`. The `PageView` is
/// non-swipeable when N == 1 and the dot indicator hides for the
/// same case — single-asset surface is identical to today, just
/// without the swipe / dots.
///
/// Telegram parity: per-entry state lives on each `ComposeEntry`
/// (composer controller, viewer transform, video controller,
/// persistent editor layers); chrome is shared and rebinds to the
/// focused entry on page change. Rasterisation is lazy — edits stay
/// as vector state on the layers until `handleSubmit` walks each
/// entry's `resolveOutputMedia`.
class ComposePage with Screen<List<ComposeResult>?>, Emitter {
  /// Standalone: creates one fresh [ComposeEntry] per input media,
  /// disposes all entries on pop. Used by camera / file-pick flows
  /// that don't have a long-lived picker scope to hold per-asset
  /// edits across re-entries.
  ComposePage({
    required this.assets,
    this.onSubmit,
    this.purpose = ComposePurpose.mediaMessage,
    this.maxImageExtent,
  }) : _borrowedEntries = null,
       ownsEntries = true,
       initialSourceRect = null,
       initialSnapshot = null,
       initialSourceRadius = BorderRadius.zero,
       transitionSourceFor = null;

  /// Borrowed: reuses entries owned by the caller (the picker).
  /// The caller is responsible for disposal — `dispose()` skips the
  /// entry-loop so per-asset state (crop / draw / caption / rendered
  /// preview) survives re-entry of compose during one picker session.
  ///
  /// [initialSourceRect] / [initialSnapshot] (optional) drive the
  /// gallery-style open hero-flight from the picker thumbnail into
  /// the compose fit-rect. Close-time lookup is delegated to
  /// [transitionSourceFor] so the picker (which knows its visible
  /// view) returns the right cell — matches telegram's
  /// `MediaPickerScreen.transitionView(for:)`. [onSubmit] fires
  /// **before** pop so the chat bubble(s) exist by the time the
  /// close hero captures its destination.
  ComposePage.borrowed({
    required List<ComposeEntry> entries,
    this.initialSourceRect,
    this.initialSnapshot,
    this.initialSourceRadius = BorderRadius.zero,
    this.transitionSourceFor,
    this.onSubmit,
    this.purpose = ComposePurpose.mediaMessage,
    this.maxImageExtent,
  }) : assets = [for (final e in entries) e.input],
       _borrowedEntries = entries,
       ownsEntries = false;

  /// The media being composed.
  final List<XMedia> assets;

  /// What the results are for.
  final ComposePurpose purpose;

  /// Longest edge, in pixels, of an avatar result's
  /// [ComposeResult.imageBytes]; absent keeps the image's own size.
  final int? maxImageExtent;

  bool get _showsCaption => purpose == ComposePurpose.mediaMessage;

  /// Caller-provided submit handler. Compose awaits this with the
  /// per-entry results before popping; the returned cids are used
  /// as the close hero destination.
  final ComposeSubmitCallback? onSubmit;

  /// True when this page owns the entries (standalone mode); false
  /// when entries are borrowed from a host (picker). Drives the
  /// `dispose()` decision.
  final bool ownsEntries;
  final List<ComposeEntry>? _borrowedEntries;

  /// Opening thumbnail bounds; absence uses an in-place media fade.
  final Rect? initialSourceRect;

  /// Picker-side bubble snapshot at push time. Disposed on screen
  /// removal so the GPU bitmap doesn't leak.
  final ui.Image? initialSnapshot;

  /// Opening thumbnail corners, applied by the flight.
  final BorderRadius initialSourceRadius;

  /// Picker-provided lookup for the close hero-flight destination.
  /// Closes over the picker's current `_displayMode` so dismiss
  /// always lands on whichever view (grid or strip) is in front.
  /// Absence uses an in-place fade and shrink.
  final GallerySource? Function(Object id)? transitionSourceFor;

  /// One entry per asset: the borrowed ones, else created here.
  late final List<ComposeEntry> entries =
      _borrowedEntries ?? [for (final m in assets) ComposeEntry(input: m)];

  /// Pages between entries.
  late final PageController pageController = PageController();

  /// Index of the entry in front.
  late final ValueNotifier<int> currentIndex = ValueNotifier<int>(0);

  /// Focus of the caption field.
  late final FocusNode composerFocus = FocusNode();

  /// Key of the caption field's bubble.
  late final GlobalKey composerBubbleKey = GlobalKey();

  /// Vertical offset of a drag-to-dismiss in progress.
  late final ValueNotifier<double> dragOffset = ValueNotifier<double>(0);

  /// The entry in front.
  ComposeEntry get focusedEntry => entries[currentIndex.value];

  /// Heights of the floating top bar and bottom strip. Measured by
  /// `OnSize` and read by the editor's LayoutBuilder to compute the
  /// fit rect (so the image animates between compose / tool screens
  /// in one shared coord system, not just within their respective
  /// padded surfaces).
  late final ValueNotifier<double> _topBarHeight = ValueNotifier<double>(0);
  late final ValueNotifier<double> _bottomStripHeight = ValueNotifier<double>(
    0,
  );

  Size? _lastBody;
  double _safeAreaTop = 0;
  bool _active = true;
  bool _topBarMeasured = false;
  bool _bottomStripMeasured = false;

  /// Result returned by [onSubmit] right before `pop`: per-entry cids
  /// paired with a closure that resolves the just-mounted chat
  /// bubble's transition source. Null when compose closes via Cancel
  /// (no submit) — the close hero then falls back to the picker source
  /// via [transitionSourceFor].
  ChatSendResult? _submitted;
  bool _submitStarted = false;

  /// Mirrors `MediaPickerScreenImpl.completed` in telegram-iOS
  /// [MediaPickerScreen.swift:263](../../../../projects/telegram-ios/submodules/MediaPickerUI/Sources/MediaPickerScreen.swift#L263).
  /// Set true at `handleSubmit` entry; reset 1.5s later via
  /// [_completedReset] (a `Chrono` so it pauses while the app is
  /// backgrounded and stays inert in widget tests where the binding
  /// lifecycle isn't `resumed`). ComposePage is the inner-analog of
  /// telegram's `controllerNode.send()`.
  bool _completed = false;
  Chrono? _completedReset;

  /// Resolve the source for the close hero on the focused entry.
  /// On Send: target the chat bubble exclusively — if it hasn't
  /// registered yet, return null for an in-place fade and shrink.
  /// On Cancel: fall through to the picker cell via
  /// [transitionSourceFor].
  GallerySource? _closeSourceForFocus() {
    final i = currentIndex.value;
    final s = _submitted;
    if (s != null && i < s.cids.length) {
      return s.sourceForCid(s.cids[i]);
    }
    if (_submitStarted) return null;
    final assetId = focusedEntry.sourceId;
    if (assetId == null) return null;
    return transitionSourceFor?.call(assetId);
  }

  @override
  Duration get transitionDuration => kMediaFlightDuration;

  @override
  Widget buildTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) => GalleryTransition(
    animation: animation,
    snapshot: initialSnapshot,
    sourceRect: initialSourceRect,
    sourceRadius: initialSourceRadius,
    closeSourceLookup: _closeSourceForFocus,
    onStage: _stage,
    onDetach: _releaseHideSlot,
    child: child,
  );

  bool _onstage = false;

  void _stage() {
    _onstage = true;
    _syncHideSlot();
  }

  void _releaseHideSlot() {
    _onstage = false;
    final slot = _hideSlot;
    if (slot != null) HiddenMediaController.instance.release(slot);
    _hideSlot = null;
  }

  HideSlot? _hideSlot;
  bool _hideListenerAttached = false;

  @override
  void onPush() {
    super.onPush();
    if (focusedEntry.input is VideoMedia) {
      focusedEntry.ensureVideoInitialized();
    }
  }

  @override
  void onActive() {
    super.onActive();
    _active = true;
    _publish();
    if (!_hideListenerAttached) {
      currentIndex.addListener(_syncHideSlot);
      _hideListenerAttached = true;
    }
  }

  /// Whichever target should currently be hidden behind compose. Before
  /// Send: the picker bubble for the focused entry (so it doesn't peek
  /// through the open hero). After Send: the just-mounted chat bubble
  /// for the focused entry (so it doesn't pop into view before the
  /// close morph lands). Mirrors telegram's
  /// `destinationView.isHidden = true` on `MediaEditorScreen.swift:4653`.
  Object? _currentHideId() {
    final i = currentIndex.value;
    final s = _submitted;
    if (s != null && i < s.cids.length) return s.cids[i];
    return focusedEntry.sourceId;
  }

  void _syncHideSlot() {
    if (!_onstage) return;
    final id = _currentHideId();
    final slot = _hideSlot;
    if (slot == null) {
      if (id != null) {
        _hideSlot = HiddenMediaController.instance.acquire(id);
      }
    } else if (id != null) {
      HiddenMediaController.instance.update(slot, id);
    }
  }

  @override
  void onRemoved() {
    if (_hideListenerAttached) {
      currentIndex.removeListener(_syncHideSlot);
      _hideListenerAttached = false;
    }
    _releaseHideSlot();
    super.onRemoved();
  }

  @override
  void onInactive() {
    super.onInactive();
    _active = false;
  }

  void _publish() {
    final body = _lastBody;
    // Skip until both floating chromes have been measured at least
    // once. Otherwise an early publish with their heights still 0
    // would push a wrong rect, the camera animator would target it,
    // and the next publish (after OnSize fires) would correct —
    // visible as a brief shrink-then-enlarge detour during the
    // compose↔tool transition.
    if (body == null ||
        !_active ||
        disposed ||
        !_topBarMeasured ||
        !_bottomStripMeasured) {
      return;
    }
    final topGutter = math.max(_safeAreaTop, kEditorSurfacePadding);
    final rect = Rect.fromLTRB(
      kEditorSurfacePadding,
      _topBarHeight.value + topGutter,
      body.width - kEditorSurfacePadding,
      body.height - _bottomStripHeight.value - kEditorSurfacePadding,
    );
    focusedEntry.setFitRect(rect);
  }

  void _onPageChanged(int i) {
    final prev = entries[currentIndex.value];
    if (prev.input is VideoMedia) prev.disposeVideo();
    currentIndex.value = i;
    final next = entries[i];
    if (next.input is VideoMedia) next.ensureVideoInitialized();
    // Carry the measured fit rect across to the swiped-to entry so
    // its first paint fits without waiting for a layout change.
    next.setFitRect(prev.fitRect.value);
  }

  /// Walk each entry and capture (a) the original picker media,
  /// (b) the in-memory composited image for edited entries, then
  /// invoke [onSubmit] **before** pop so the chat bubbles exist by
  /// the time the close hero captures its destination. Mirrors
  /// telegram's `completion(results, finishedCallback)` order:
  /// insert first, then `animateOut(finished: true)`.
  Future<void> handleSubmit() async {
    if (_completed) return;
    _completed = true;
    _submitStarted = true;
    _completedReset?.cancel();
    _completedReset = Chrono(const Duration(milliseconds: 1500), () {
      _completed = false;
    });
    final results = <ComposeResult>[];
    for (final e in entries) {
      final composed = await e.composedImage();
      results.add(
        ComposeResult(
          source: e.input,
          composedImage: composed,
          caption: _showsCaption
              ? MediaHost.current.caption(e.composerController)
              : null,
          videoEdit: e.videoEdit.hasEdits ? e.videoEdit : null,
          imageBytes: purpose == ComposePurpose.avatar
              ? (_avatarBytes(e.input, await e.captureImage(), maxImageExtent)
                  ..ignore())
              : null,
        ),
      );
    }
    final submit = onSubmit;
    _submitted = await submit?.call(results);
    // Repoint the hide slot at the just-mounted chat bubble so it
    // stays invisible behind the close morph; the snapshot lands on
    // an empty rect and the bubble unhides when compose is removed.
    _syncHideSlot();
    // The inserted bubble registers its source during the next build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (disposed) return;
      pop(results);
    });
    // onSubmit normally dirties the chat tree (placeholder bubble mounts),
    // which schedules the frame the post-frame callback runs after. When
    // onSubmit is null or a no-op, nothing else requests a frame — make
    // sure one is scheduled so the pop is reachable.
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Pops without a result.
  void handleCancel() => pop();

  /// Drop composer focus on the first pointer that lands inside the
  /// preview area. Lets the user tap-anywhere to put the soft keyboard
  /// away when they're done writing a caption.
  void _maybeDismissKeyboard(PointerDownEvent _) {
    if (composerFocus.hasFocus) composerFocus.unfocus();
  }

  /// Open a tool (crop / draw) — drop composer focus first so the
  /// soft keyboard dismisses, and bake any user pan/zoom into the
  /// entry's camera so the tool's animator interpolates from what the
  /// user is currently looking at (instead of snapping back to fit).
  Future<void> _openTool(Future<void> Function() open) async {
    if (composerFocus.hasFocus) composerFocus.unfocus();
    focusedEntry.bakeViewerTransform();
    await open();
  }

  @override
  Widget buildPresenter(BuildContext context) {
    _safeAreaTop = MediaQuery.viewPaddingOf(context).top;
    return Scaffold(
      backgroundColor: const Color(0x00000000),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const Positioned.fill(
            child: MediaFlightChrome(
              child: ColoredBox(color: Color(0xFF000000)),
            ),
          ),
          Positioned.fill(
            child: ListenableBuilder(
              listenable: Listenable.merge([_topBarHeight, _bottomStripHeight]),
              builder: (ctx, _) => LayoutBuilder(
                builder: (ctx2, constraints) {
                  _lastBody = constraints.biggest;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _publish();
                  });
                  return ListenableBuilder(
                    listenable: dragOffset,
                    builder: (ctx3, _) {
                      final viewport = MediaQuery.sizeOf(ctx3).height;
                      final dismissDistance = viewport / 4;
                      final progress = dismissDistance == 0
                          ? 0.0
                          : (dragOffset.value.abs() / dismissDistance).clamp(
                              0.0,
                              1.0,
                            );
                      final scale = 1 - 0.1 * progress;
                      return Transform.scale(
                        scale: scale,
                        alignment: Alignment.topCenter,
                        child: Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: _maybeDismissKeyboard,
                          child: ValueListenableBuilder<int>(
                            valueListenable: currentIndex,
                            builder: (ctx4, _, _) => DismissCarrier(
                              blocked: focusedEntry.isZoomed,
                              dragOffset: dragOffset,
                              onDismissCommitted: handleCancel,
                              child: PageView.builder(
                                controller: pageController,
                                itemCount: entries.length,
                                onPageChanged: _onPageChanged,
                                physics: entries.length > 1
                                    ? null
                                    : NeverScrollableScrollPhysics(),
                                itemBuilder: (ctx5, i) => ComposeEntryView(
                                  entry: entries[i],
                                  flightEnabled: i == currentIndex.value,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          // Floating top bar over the editor.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MediaFlightChrome(
              child: OnSize(
                onSize: (s) {
                  _topBarMeasured = true;
                  _topBarHeight.value = s.height;
                },
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: EdgeInsets.only(left: 8, top: 4, bottom: 4),
                    child: Row(
                      children: [
                        Touch(
                          onPress: handleCancel,
                          child: Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colors.onMedia.withValues(alpha: 0.15),
                            ),
                            child: Icon(
                              CupertinoIcons.xmark,
                              color: colors.onMedia,
                              size: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Floating bottom strip (dot indicator + command bar +
          // composer) inside KeyboardInsets so it tracks the soft
          // keyboard.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: MediaFlightChrome(
              child: OnSize(
                onSize: (s) {
                  _bottomStripMeasured = true;
                  _bottomStripHeight.value = s.height;
                },
                child: MediaHost.current.keyboardInsets(
                  builder: (context, bottom) => Container(
                    // Pad the bottom safe area / keyboard area INSIDE
                    // the colored container so its background covers the
                    // gap. Otherwise an InteractiveViewer-zoomed image
                    // beneath shows through the bottom safe-area strip.
                    color: const Color(0xCC000000),
                    padding: EdgeInsets.only(bottom: bottom),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (entries.length > 1)
                          ValueListenableBuilder<int>(
                            valueListenable: currentIndex,
                            builder: (context, i, _) =>
                                _DotIndicator(count: entries.length, active: i),
                          ),
                        ValueListenableBuilder<int>(
                          valueListenable: currentIndex,
                          builder: (context, _, _) {
                            final e = focusedEntry;
                            if (e.input is! VideoMedia) {
                              return SizedBox.shrink();
                            }
                            // Telegram places the trim scrubber directly
                            // above the caption bar; it mounts once the
                            // preview controller knows the duration.
                            return ListenableBuilder(
                              listenable: e,
                              builder: (context, _) {
                                final ctrl = e.videoController;
                                if (ctrl == null || !ctrl.value.isInitialized) {
                                  return SizedBox.shrink();
                                }
                                return VideoTrimScrubber(
                                  entry: e,
                                  duration: ctrl.value.duration,
                                );
                              },
                            );
                          },
                        ),
                        if (_showsCaption)
                          ValueListenableBuilder<int>(
                            valueListenable: currentIndex,
                            builder: (context, _, _) =>
                                MediaHost.current.captionField(
                                  bubbleKey: composerBubbleKey,
                                  controller: focusedEntry.composerController,
                                  focusNode: composerFocus,
                                  onSubmit: handleSubmit,
                                  placeholder: strings.addACaption,
                                ),
                          ),
                        ValueListenableBuilder<int>(
                          valueListenable: currentIndex,
                          builder: (context, _, _) {
                            final e = focusedEntry;
                            // Video tools edit poster-frame geometry.
                            final editable =
                                e.input is ImageMedia || e.input is VideoMedia;
                            return MediaCommandsBar(
                              onCrop: editable
                                  ? () => _openTool(e.openCropEditor)
                                  : null,
                              onDraw: editable
                                  ? () => _openTool(e.openDrawEditor)
                                  : null,
                            );
                          },
                        ),
                        if (!_showsCaption)
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              space.lg,
                              0,
                              space.lg,
                              space.md,
                            ),
                            child: SizedBox(
                              width: double.infinity,
                              child: MediaHost.current.confirmButton(
                                onPressed: handleSubmit,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _completedReset?.cancel();
    if (ownsEntries) {
      for (final e in entries) {
        e.dispose();
      }
    } else {
      // Borrowed entries survive the compose session (picker-owned
      // edits) but their preview players must not — the looping video
      // (and its audio) would keep running under the picker grid.
      // Re-entering compose re-initializes the controller.
      for (final e in entries) {
        e.disposeVideo().unawaited();
      }
    }
    initialSnapshot?.dispose();
    pageController.dispose();
    currentIndex.dispose();
    composerFocus.dispose();
    dragOffset.dispose();
    _topBarHeight.dispose();
    _bottomStripHeight.dispose();
    super.dispose();
  }
}

/// Dot row indicator above the composer — telegram's album-page visual.
/// Hidden when there's only one entry. Active dot is filled `colors.onMedia`;
/// inactive dots are dimmed to 40% alpha.
class _DotIndicator extends StatelessWidget {
  const _DotIndicator({required this.count, required this.active});

  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 3),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == active
                      ? colors.onMedia
                      : colors.onMedia.withValues(alpha: 0.4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
