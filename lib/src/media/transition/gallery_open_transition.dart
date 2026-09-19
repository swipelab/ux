import 'dart:ui' as ui;

import 'package:ux/src/media/timing.dart';
import 'package:ux/src/media/transition/fit_rect.dart';
import 'package:flutter/widgets.dart';

/// Drives the gallery's open animation: a captured snapshot of the source
/// bubble morphs from its on-screen rect to fullscreen while the gallery
/// shell fades in underneath.
///
/// Mirrors `ChatImageGalleryItem.swift:1004-1069` (`animateIn`):
///   - copyView position bubble → fullscreen, **210ms** spring (`:1046`)
///   - copyView size → fullscreen, **250ms** spring (`:1050`)
///   - copyView alpha 1 → 0, **200ms** linear (`:1040`)
///   - background dim 0 → 1, **150ms** linear (`GalleryControllerNode.swift:434`)
///   - content alpha 0 → 1, **100ms** (`:1061`) — Phase 8 wires the actual
///     gallery content fade; Phase 6 v1 only animates the shell's overall
///     opacity (the dim) since the gallery shell is just a black rect.
///
/// Phase 6 v1 ships a **single-snapshot** version. iOS uses two snapshots
/// (copyView + surfaceCopyView, the latter reparented into a chat-side
/// overlay) to bridge two view trees during the cross-window animation;
/// Flutter has a single render tree so one snapshot suffices visually.
/// Plan §12.4 documents this as a phase-end retrospective decision.
class GalleryOpenTransition extends StatelessWidget {
  /// Creates the open transition.
  const GalleryOpenTransition({
    super.key,
    required this.animation,
    required this.snapshot,
    required this.sourceRect,
    required this.child,
    this.destinationContentSize,
  });

  /// Animation 0..1 over the screen's transition duration. Wall-clock
  /// timings of the sub-intervals are computed against [_totalMs] —
  /// iOS-faithful at every cited fraction regardless of the screen
  /// driver's duration.
  final Animation<double> animation;

  /// Captured visual of the source bubble. Null if capture failed —
  /// transition still runs but only the dim fade is visible.
  final ui.Image? snapshot;

  /// Bubble's rect in the gallery's local coordinates (== screen coords for
  /// a fullscreen [PopupRoute]).
  final Rect sourceRect;

  /// Intrinsic photo dimensions used to compute the **destination
  /// fit-rect** inside the viewport. iOS animates the snapshot to the
  /// photo's actual display rect (`ChatImageGalleryItem.swift:1014-1016`,
  /// `contentNode.view.bounds` converted to self.view's coords) — which
  /// equals the fit-rect, **not** the fullscreen rect. When the photo
  /// has a different aspect ratio from the viewport (portrait photo on
  /// landscape viewport, or vice versa), the destination is letterboxed
  /// inside the viewport. Null falls back to fullscreen for non-photo
  /// items where letterboxing isn't applicable.
  final Size? destinationContentSize;

  /// The gallery shell underneath the snapshot.
  final Widget child;

  // The iOS open's longest sub-anim is `kGalleryOpenPushed` (450ms — the
  // chat-side `pushedTransition`). Phase 6 v1 does not implement that
  // chat-coupled effect, so the longest in-gallery sub-anim is the spatial
  // bounds at 250ms. Matching the host Screen's transitionDuration (also
  // 250ms) keeps every cited sub-interval at the right wall-clock time.
  static const _totalMs = 250;

  static double _frac(Duration d) => d.inMilliseconds / _totalMs;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Offset.zero & constraints.biggest;
        final destinationRect = fitRect(destinationContentSize, viewport);

        // Sub-animations clamped to their iOS-faithful durations within the
        // route's 450ms total. Each Interval(0, sub/total) makes the curve
        // reach 1.0 at sub-duration and stay flat after.
        final dimAlpha = CurvedAnimation(
          parent: animation,
          curve: Interval(0.0, _frac(kGalleryOpenChrome)),
        );
        final copyPosition = CurvedAnimation(
          parent: animation,
          curve: Interval(
            0.0,
            _frac(kGalleryOpenPosition),
            curve: kGalleryIosSpringBezier,
          ),
        );
        final copyBounds = CurvedAnimation(
          parent: animation,
          curve: Interval(
            0.0,
            _frac(kGalleryOpenBounds),
            curve: kGalleryIosSpringBezier,
          ),
        );
        final copyAlpha = CurvedAnimation(
          parent: animation,
          curve: Interval(0.0, _frac(kGalleryOpenCopyAlpha)),
        );

        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            return Stack(
              children: <Widget>[
                Opacity(opacity: dimAlpha.value, child: child),
                if (snapshot != null)
                  _buildSnapshot(
                    copyPosition.value,
                    copyBounds.value,
                    copyAlpha.value,
                    sourceRect,
                    destinationRect,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSnapshot(
    double positionT,
    double boundsT,
    double alphaT,
    Rect source,
    Rect destination,
  ) {
    final centerX =
        source.center.dx + (destination.center.dx - source.center.dx) * positionT;
    final centerY =
        source.center.dy + (destination.center.dy - source.center.dy) * positionT;
    final width =
        source.width + (destination.width - source.width) * boundsT;
    final height =
        source.height + (destination.height - source.height) * boundsT;
    final rect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: width,
      height: height,
    );
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      // The snapshot is a purely visual overlay — it must not intercept
      // pointer events, otherwise (a) the still-rendered fullscreen-sized
      // snapshot at the END of the open transition (animation.value=1.0)
      // would block all taps/pinches/drags that should reach the gallery
      // content underneath, and (b) during the morph, mid-flight pointer
      // events would land on the snapshot instead of the photo. Without
      // this `IgnorePointer`, double-tap-zoom / pinch / drag-to-dismiss
      // all silently fail post-open.
      child: IgnorePointer(
        child: Opacity(
          opacity: (1.0 - alphaT).clamp(0.0, 1.0),
          child: RawImage(
            image: snapshot,
            width: rect.width,
            height: rect.height,
            fit: BoxFit.fill,
          ),
        ),
      ),
    );
  }
}
