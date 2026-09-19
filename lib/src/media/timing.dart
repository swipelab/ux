import 'package:flutter/animation.dart';

/// GalleryControllerNode.swift:434 (backgroundColor) and :436 (chrome alpha).
const kGalleryOpenChrome = Duration(milliseconds: 150);

/// ChatImageGalleryItem.swift:1044 — `positionDuration = 0.21`.
const kGalleryOpenPosition = Duration(milliseconds: 210);

/// ChatImageGalleryItem.swift:1064 — content node bounds + copyView scale.
const kGalleryOpenBounds = Duration(milliseconds: 250);

/// GalleryControllerNode.swift:463 — chatController.pushedTransition.
const kGalleryOpenPushed = Duration(milliseconds: 450);

/// ChatImageGalleryItem.swift:1040 — copyView alpha 1→0.
const kGalleryOpenCopyAlpha = Duration(milliseconds: 200);

/// ChatImageGalleryItem.swift:1141-1152 — content/copy/surface position+bounds.
const kGalleryCloseSpatial = Duration(milliseconds: 250);

/// GalleryControllerNode.swift:484, 486, 494, 499 — canonical close path.
const kGalleryCloseChrome = Duration(milliseconds: 100);

/// Close-transition shrink factor when the resolved destination rect
/// is off-screen. The snapshot fades + scales down in place to this
/// fraction of its source size — a translate-to-off-screen morph
/// would look like a fast disappearing zoom. Banlu-specific UX choice;
/// Telegram uses an explicit `forceAway:true` flag for the equivalent
/// "no morph, just dismiss" path (`ChatImageGalleryItem.swift:1494`).
const double kGalleryCloseFadeShrinkScale = 0.85;

/// GalleryControllerNode.swift:567 — `abs(velocity.y) > 1.0`. iOS's
/// `UIScrollViewDelegate.scrollViewWillEndDragging` reports `velocity`
/// in **points per millisecond** (per Apple's docs), so the iOS
/// constant `1.0` translates to **1000 px/s** in Flutter's
/// `Velocity.pixelsPerSecond` units.
const kGalleryDismissVelocity = 1000.0;

/// `SwipeToDismissGestureRecognizer.swift:85` — the dismiss recognizer
/// fails itself once `abs(translation.x) > 5.0` so a horizontal page
/// swipe with vertical drift cedes cleanly to the pager. See §13a.9.
const kGalleryDismissXSlop = 5.0;

/// `kCAMediaTimingFunctionSpring` non-0.5s path — cubic-Bezier control points
/// at CAAnimationUtils.swift:173: `controlPoints: 0.380, 0.700, 0.125, 1.000`.
const kGalleryIosSpringBezier = Cubic(0.380, 0.700, 0.125, 1.000);

/// `customSpring(damping=180, initialVelocity=0)` resolved by
/// CAAnimationUtils.swift:73-105 with mass=5.0 (line 88), stiffness=900.0
/// (line 89), damping=180 / vel=0 (lines 75-76, 86-87).
const kGalleryCustomSpring = SpringDescription(
  mass: 5.0,
  stiffness: 900.0,
  damping: 180.0,
);

/// Gallery center-status disc diameter. Mirrors
/// `UniversalVideoGalleryItem.swift:1259-1262` `statusDiameter = 50.0`.
const double kCenterStatusDiameter = 50.0;
