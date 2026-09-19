import 'dart:ui' as ui;

import 'package:ux/src/media/timing.dart';
import 'package:ux/src/media/transition/fit_rect.dart';
import 'package:flutter/widgets.dart';

/// Drives the gallery's close animation: the snapshot morphs from fullscreen
/// back to the source bubble's rect while the shell dim fades out.
///
/// Mirrors `ChatImageGalleryItem.swift:1071-1156` (`animateOut`):
///   - Spatial morph (position + bounds): **250ms** spring (`:1141-1152`).
///   - Shell dim 1→0: **100ms** linear (`GalleryControllerNode.swift:484`).
///
/// **Live re-fetch of the destination**: iOS re-queries the bubble's current
/// rect at `dismiss(forceAway:)` time (`:1494`) so a chat scroll between
/// open and close lands the snapshot on the right rect. We mirror this by
/// taking a [destinationLookup] closure — the route invokes `currentRect`
/// at close start. Locked at [initState]; the chosen destination doesn't
/// shift mid-animation (matches iOS's lock behaviour).
///
/// Phase 7 v1 ships a **single-snapshot** version like Phase 6. iOS has
/// copyView fading 1→0 over 80ms while surfaceCopyView fades 0→1 over 25ms
/// at close start; we simplify to a single snapshot at full opacity that
/// stays visible throughout the morph.
class GalleryCloseTransition extends StatefulWidget {
  /// Creates the close transition.
  const GalleryCloseTransition({
    super.key,
    required this.animation,
    required this.snapshot,
    required this.destinationLookup,
    required this.fallbackDestinationRect,
    required this.child,
    this.sourceContentSize,
    this.sourceTranslation = Offset.zero,
  });

  /// Route's animation; goes **1 → 0** over `reverseTransitionDuration`
  /// (= [kGalleryCloseSpatial] = 250ms).
  final Animation<double> animation;

  /// Captured snapshot from open (or null if unavailable).
  final ui.Image? snapshot;

  /// Live re-fetch of the destination rect. Called once in [initState];
  /// returns null if the source is no longer registered.
  final Rect? Function() destinationLookup;

  /// Used when [destinationLookup] returns null. Typically the rect captured
  /// at open time (best guess if the bubble has scrolled offscreen).
  final Rect fallbackDestinationRect;

  /// Intrinsic photo dimensions used to compute the **source fit-rect**
  /// inside the viewport. iOS animates from the photo's actual display
  /// rect (`ChatImageGalleryItem.swift:1100-1115`,
  /// `transformedCopyViewInitialFrame = contentNode.view.convert(...)`),
  /// which equals the fit-rect — **not** the fullscreen rect. When the
  /// photo is letterboxed (different aspect from viewport), the source
  /// rect is the smaller fit-rect inside the viewport. Null falls back
  /// to fullscreen for non-photo items.
  final Size? sourceContentSize;

  /// Per-axis offset added to the source rect at the start of the close.
  /// This carries the dismiss-carrier's drag delta forward — when the
  /// user releases past threshold mid-drag, the photo's *current*
  /// on-screen position is `fit-rect + dragOffset`, not the at-rest
  /// `fit-rect`. Without this offset the snapshot snaps back to rest at
  /// t=0 of the close while the shell underneath is still mid-drag,
  /// producing a one-frame "gallery fully-opened again" flicker. iOS
  /// avoids this naturally because `transformedCopyViewInitialFrame`
  /// (`ChatImageGalleryItem.swift:1093`) is read from the photo's
  /// already-translated layer at dismiss-commit time. Default
  /// `Offset.zero` matches the swipe-back / nav-bar-back paths where
  /// the close starts from rest.
  final Offset sourceTranslation;

  /// The gallery shell underneath the snapshot.
  final Widget child;

  @override
  State<GalleryCloseTransition> createState() =>
      _GalleryCloseTransitionState();
}

class _GalleryCloseTransitionState extends State<GalleryCloseTransition> {
  late final Rect _destination;

  @override
  void initState() {
    super.initState();
    _destination = widget.destinationLookup() ?? widget.fallbackDestinationRect;
  }

  static int get _totalMs => kGalleryCloseSpatial.inMilliseconds;

  static double _frac(Duration d) => d.inMilliseconds / _totalMs;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Offset.zero & constraints.biggest;
        // iOS-faithful source: the photo's fit-rect translated by any
        // dismiss-carrier drag offset that was active at commit. See
        // `sourceTranslation` doc + `behavior.md` §7 on open/close.
        // When [sourceContentSize] is null (non-photo item or no item),
        // we fall back to the viewport.
        final source = fitRect(widget.sourceContentSize, viewport)
            .shift(widget.sourceTranslation);
        // When the user paged to a sibling whose chat-row is no longer
        // mounted in the viewport, the resolved destination rect lives
        // entirely outside the viewport. Animating to it would look
        // like a fast disappearing zoom toward a missing target.
        // Switch to a fade + slight shrink in place instead.
        final destinationOffScreen = !viewport.overlaps(_destination);
        return AnimatedBuilder(
          animation: widget.animation,
          builder: (context, _) {
            // Route animation reverses 1→0; "close progress" goes 0→1.
            final close = 1.0 - widget.animation.value;

            // Shell dim 1→0; reaches 0 at 100ms = 0.4 of the 250ms close.
            final dimProgress =
                (close / _frac(kGalleryCloseChrome)).clamp(0.0, 1.0);
            final dimAlpha = (1.0 - dimProgress).clamp(0.0, 1.0);

            final Rect rect;
            final double snapshotAlpha;
            if (destinationOffScreen) {
              // Fade-shrink in place. Linear scale from 1.0 to
              // kGalleryCloseFadeShrinkScale around the source center;
              // alpha 1→0 across the same close progress.
              final scaleT = 1.0 -
                  close * (1.0 - kGalleryCloseFadeShrinkScale);
              rect = Rect.fromCenter(
                center: source.center,
                width: source.width * scaleT,
                height: source.height * scaleT,
              );
              snapshotAlpha = (1.0 - close).clamp(0.0, 1.0);
            } else {
              // Spatial morph (source-fit-rect → destination), spring-curved.
              final positionT = kGalleryIosSpringBezier.transform(close);
              final centerX = source.center.dx +
                  (_destination.center.dx - source.center.dx) * positionT;
              final centerY = source.center.dy +
                  (_destination.center.dy - source.center.dy) * positionT;
              final width = source.width +
                  (_destination.width - source.width) * positionT;
              final height = source.height +
                  (_destination.height - source.height) * positionT;
              rect = Rect.fromCenter(
                center: Offset(centerX, centerY),
                width: width,
                height: height,
              );
              snapshotAlpha = 1.0;
            }

            return Stack(
              children: <Widget>[
                Opacity(opacity: dimAlpha, child: widget.child),
                if (widget.snapshot != null)
                  Positioned(
                    left: rect.left,
                    top: rect.top,
                    width: rect.width,
                    height: rect.height,
                    // Visual-only overlay — must not steal pointer events.
                    // See the matching IgnorePointer in
                    // [GalleryOpenTransition._buildSnapshot] for the
                    // detailed reason.
                    child: IgnorePointer(
                      child: _maybeFade(
                        alpha: snapshotAlpha,
                        child: RawImage(
                          image: widget.snapshot,
                          width: rect.width,
                          height: rect.height,
                          fit: BoxFit.fill,
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

  /// Visible for tests — the destination rect locked at initState.
  @visibleForTesting
  Rect get destinationForTest => _destination;

  /// Wrap [child] in an [Opacity] only when the alpha is meaningfully
  /// less than 1.0. Avoids introducing a save-layer at full alpha
  /// (Flutter optimises this away at runtime, but tests' rasterisation
  /// can still differ when the widget tree contains an extra Opacity
  /// node at α=1.0).
  static Widget _maybeFade({required double alpha, required Widget child}) {
    if (alpha >= 0.999) return child;
    return Opacity(opacity: alpha, child: child);
  }
}
