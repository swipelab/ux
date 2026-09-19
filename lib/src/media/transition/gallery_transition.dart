import 'dart:ui' as ui;

import 'package:ux/src/media/timing.dart';
import 'package:ux/src/media/transition/fit_rect.dart';
import 'package:flutter/widgets.dart';

/// Single-widget container for both the gallery's open and close
/// morph. Same widget type across phases — switching types would discard
/// the shell subtree (and the carrier's latched drag) at the open→close
/// boundary. Sub-animation timings live in the `kGalleryOpen*` /
/// `kGalleryClose*` constants in design.dart.
class GalleryTransition extends StatefulWidget {
  /// Creates the transition.
  const GalleryTransition({
    super.key,
    required this.animation,
    required this.snapshot,
    required this.bubbleRect,
    required this.contentSize,
    required this.closeDestinationLookup,
    required this.closeFallbackDestinationRect,
    required this.closeSourceTranslation,
    required this.child,
    this.closeSnapshotFactory,
    this.photoRectLookup,
  });

  /// Route animation: 0 → 1 on push, 1 → 0 on pop.
  final Animation<double> animation;

  /// Captured bubble snapshot. Null = no snapshot to morph; only shell
  /// opacity animates.
  final ui.Image? snapshot;

  /// Bubble rect in screen-local coordinates at open time. Source for the
  /// open morph; close-time fallback when [closeDestinationLookup]
  /// returns null.
  final Rect bubbleRect;

  /// Photo intrinsic dimensions; drives the fit-rect inside the viewport.
  /// Null falls back to the full viewport.
  final Size? contentSize;

  /// Re-queried at close start so the morph lands on the current bubble's
  /// rect after a mid-gallery scroll. Locked exactly once.
  final Rect? Function() closeDestinationLookup;

  /// Used at close start when [closeDestinationLookup] returns null.
  final Rect closeFallbackDestinationRect;

  /// Added to the close-time source rect so the morph starts at the
  /// photo's current (dragged) position, not the at-rest fit-rect.
  final Offset closeSourceTranslation;

  /// Optional async factory invoked once at close start to re-capture the
  /// current bubble. Without it, after a pager swipe the original
  /// [snapshot] would morph into a different-aspect destination, producing
  /// visible distortion.
  final Future<ui.Image?> Function()? closeSnapshotFactory;

  /// Optional live lookup for the photo's current at-rest rect in this
  /// widget's coordinates — the open destination / close source. Hosts
  /// whose photo does not rest at the viewport fit (compose: the camera
  /// fits the crop rect into the chrome-excluding fit rect) supply this
  /// so the morph starts/ends where the photo actually paints. Null (or
  /// a null result) falls back to `fitRect(contentSize, viewport)`.
  final Rect? Function()? photoRectLookup;

  /// The gallery shell. Held at a stable widget-tree position across the
  /// open→close phase swap so element identity (and the carrier's drag)
  /// survive.
  final Widget child;

  @override
  State<GalleryTransition> createState() => _GalleryTransitionState();
}

class _GalleryTransitionState extends State<GalleryTransition> {
  /// Last non-null destination rect seen from
  /// [GalleryTransition.closeDestinationLookup]. We re-query every
  /// frame (the bubble can move mid-morph if the chat scrolls or
  /// expands) but retain the last-known rect as a fallback when the
  /// lookup briefly returns null between rebuilds.
  Rect? _lastDestRect;

  /// Snapshot of the destination view (chat bubble), captured at close
  /// start. Cross-fades in over the source snapshot during the morph —
  /// mirrors telegram's `destinationTransitionView`
  /// (`MediaEditorScreen.swift:4661,4712`). Null on tests where
  /// `RenderRepaintBoundary.toImage` rejects with `!debugNeedsPaint`.
  ui.Image? _destSnapshot;
  bool _destRequestInFlight = false;

  @override
  void initState() {
    super.initState();
    if (_isClosingStatus(widget.animation.status)) {
      _enterClosePhase();
    }
    widget.animation.addStatusListener(_handleStatus);
  }

  @override
  void didUpdateWidget(covariant GalleryTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_handleStatus);
      widget.animation.addStatusListener(_handleStatus);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_handleStatus);
    _destSnapshot?.dispose();
    super.dispose();
  }

  static bool _isClosingStatus(AnimationStatus s) =>
      s == AnimationStatus.reverse || s == AnimationStatus.dismissed;

  bool _inClosePhase = false;

  void _handleStatus(AnimationStatus status) {
    if (_isClosingStatus(status)) _enterClosePhase();
  }

  /// Latched once entering close — momentary flips back to `completed`
  /// (e.g. tests driving `controller.value` to 1) must not revert phase.
  void _enterClosePhase() {
    _inClosePhase = true;
  }

  /// Captures the destination snapshot exactly once — re-queries on
  /// each close-phase build until the factory returns a non-null image
  /// (the bubble may not be paintable yet on the same frame it mounts).
  void _maybeCaptureDestSnapshot() {
    if (_destSnapshot != null || _destRequestInFlight) return;
    final factory = widget.closeSnapshotFactory;
    if (factory == null) return;
    _destRequestInFlight = true;
    factory().then((image) {
      _destRequestInFlight = false;
      if (!mounted) {
        image?.dispose();
        return;
      }
      if (image == null) return;
      setState(() {
        _destSnapshot?.dispose();
        _destSnapshot = image;
      });
    });
  }

  static const _totalMs = 250;
  static double _frac(Duration d) => d.inMilliseconds / _totalMs;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Offset.zero & constraints.biggest;
        return AnimatedBuilder(
          animation: widget.animation,
          child: widget.child,
          builder: (context, shellChild) {
            final isClosing =
                _inClosePhase || _isClosingStatus(widget.animation.status);
            final geometry =
                isClosing ? _close(viewport) : _open(viewport);
            final srcImage = widget.snapshot;
            final destImage = isClosing ? _destSnapshot : null;

            return Stack(
              children: <Widget>[
                Opacity(opacity: geometry.shellOpacity, child: shellChild),
                if (destImage != null)
                  Positioned(
                    left: geometry.rect.left,
                    top: geometry.rect.top,
                    width: geometry.rect.width,
                    height: geometry.rect.height,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: geometry.destSnapshotOpacity,
                        child: RawImage(
                          image: destImage,
                          width: geometry.rect.width,
                          height: geometry.rect.height,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                if (srcImage != null)
                  Positioned(
                    left: geometry.rect.left,
                    top: geometry.rect.top,
                    width: geometry.rect.width,
                    height: geometry.rect.height,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: geometry.snapshotOpacity,
                        child: RawImage(
                          image: srcImage,
                          width: geometry.rect.width,
                          height: geometry.rect.height,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Rect _photoRect(Rect viewport) =>
      widget.photoRectLookup?.call() ?? fitRect(widget.contentSize, viewport);

  _Geometry _open(Rect viewport) {
    final destination = _photoRect(viewport);
    final source = widget.bubbleRect;
    final v = widget.animation.value;

    final dimAlphaT = (v / _frac(kGalleryOpenChrome)).clamp(0.0, 1.0);
    final positionT = kGalleryIosSpringBezier
        .transform((v / _frac(kGalleryOpenPosition)).clamp(0.0, 1.0));
    final boundsT = kGalleryIosSpringBezier
        .transform((v / _frac(kGalleryOpenBounds)).clamp(0.0, 1.0));
    final copyAlphaT = (v / _frac(kGalleryOpenCopyAlpha)).clamp(0.0, 1.0);

    return _Geometry(
      rect: _morph(source, destination, positionT: positionT, boundsT: boundsT),
      shellOpacity: dimAlphaT,
      snapshotOpacity: (1.0 - copyAlphaT).clamp(0.0, 1.0),
    );
  }

  _Geometry _close(Rect viewport) {
    _maybeCaptureDestSnapshot();
    final source = _photoRect(viewport).shift(widget.closeSourceTranslation);
    final lookup = widget.closeDestinationLookup();
    if (lookup != null) _lastDestRect = lookup;
    final destination = _lastDestRect ?? widget.closeFallbackDestinationRect;
    final hasDestination = _lastDestRect != null;
    final close = 1.0 - widget.animation.value;

    // Until we have a real destination (the chat bubble's
    // `GallerySource` only registers on the build after the
    // placeholder mounts), keep the morph anchored at source — no
    // detour through the open-time fallback rect.
    final positionT =
        hasDestination ? kGalleryIosSpringBezier.transform(close) : 0.0;
    final boundsT = positionT;

    // Telegram-faithful close (`MediaEditorScreen.swift:4580-4750`),
    // mapped to fractions of the route's reverse animation:
    //   - source preview alpha 1→0 over 0.25s/0.4s = 0.625 of close
    //   - destination snapshot alpha 0→1 over 0.25s, delayed 0.15s
    //     → starts at 0.375 of close, ends at 1.0
    //   - editor chrome (shell) alpha 1→0 over 0.25s = 0.625 of close
    // The destination bubble is hidden behind the cross-fade via
    // `HiddenMediaController` for the entire morph.
    const srcAlphaFraction = 0.625;
    const destAlphaStart = 0.375;
    const destAlphaFraction = 0.625;

    final srcOpacity = (1.0 - close / srcAlphaFraction).clamp(0.0, 1.0);
    final destOpacity =
        ((close - destAlphaStart) / destAlphaFraction).clamp(0.0, 1.0);
    final shellOpacity = srcOpacity;

    return _Geometry(
      rect: _morph(source, destination, positionT: positionT, boundsT: boundsT),
      shellOpacity: shellOpacity,
      snapshotOpacity: srcOpacity,
      destSnapshotOpacity: destOpacity,
    );
  }

  Rect _morph(Rect from, Rect to,
      {required double positionT, required double boundsT}) {
    final cx = from.center.dx + (to.center.dx - from.center.dx) * positionT;
    final cy = from.center.dy + (to.center.dy - from.center.dy) * positionT;
    final w = from.width + (to.width - from.width) * boundsT;
    final h = from.height + (to.height - from.height) * boundsT;
    return Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
  }

  @visibleForTesting
  Rect? get lockedCloseDestinationForTest => _lastDestRect;
}

class _Geometry {
  _Geometry({
    required this.rect,
    required this.shellOpacity,
    required this.snapshotOpacity,
    this.destSnapshotOpacity = 0.0,
  });
  final Rect rect;
  final double shellOpacity;
  final double snapshotOpacity;

  /// Alpha for the destination-side cross-fade snapshot during close.
  /// Mirrors telegram's `destinationTransitionView` alpha
  /// (`MediaEditorScreen.swift:4662-4664`).
  final double destSnapshotOpacity;
}
