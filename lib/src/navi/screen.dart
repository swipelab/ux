import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ux/src/navi/screen_host.dart';
import 'package:ux/src/navi/transitions.dart';

/// A full-screen destination that can be pushed onto a [ScreenStack]
/// and managed by a [XRouter].
///
/// Provides its own content via [buildPresenter] and controls
/// how it transitions in/out via [buildTransition].
mixin Screen<T> {
  // === rendering ===

  /// Identity tag used by [ScreenStack] to reconcile a `home` slot:
  /// same [runtimeType] + same [key] → same surface, slot State
  /// preserved. Has no effect on stack entries (diffed by `==`).
  Key? get key => null;

  /// Build the page content.
  Widget buildPresenter(BuildContext context);

  /// Wrap [child] (the output of [buildPresenter]) in a transition
  /// driven by [animation] (0→1 on push, 1→0 on pop).
  ///
  /// Override to customise. The default is a platform slide.
  Widget buildTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) => ScreenTransitions.platformSlide(context, animation, child);

  /// Duration of the enter/exit animation.
  Duration get transitionDuration => const Duration(milliseconds: 300);

  /// Whether this screen is a modal (dialog, bottom sheet, etc.), which Esc
  /// pops while it is the top screen.
  bool get isModal => false;

  /// Whether the back gesture (the iOS edge swipe, Android's predictive back)
  /// drags this page, read as each one starts and as an edge swipe moves and
  /// lifts: an edge swipe it turns off springs back. Set to `false` for bottom
  /// sheets and overlays that dismiss differently; Android's back gesture then
  /// goes back as system back does.
  bool get canSwipeBack => true;

  /// Device orientations this screen supports while it is the topmost
  /// visible page. The router applies the topmost screen's value via
  /// [SystemChrome.setPreferredOrientations] on each active-screen
  /// change, mirroring UIKit's per-`UIViewController.supportedInterfaceOrientations`.
  /// Override to force portrait/landscape on a specific page (e.g. a camera).
  Iterable<DeviceOrientation> get supportedOrientations =>
      DeviceOrientation.values;

  // === navigation ===

  /// The host that pushed this screen — set by the host on push.
  /// Mirrors UIKit's `UIViewController.navigationController`.
  /// `null` until pushed.
  ///
  /// Pages typically don't read this directly; use [host] instead,
  /// which is the right target for "push another page from here".
  ScreenHost? parentHost;

  /// The host that pushes from inside this screen's body should
  /// target. Defaults to [parentHost] — regular screens push
  /// siblings onto their own host. `SheetScreen` overrides this to
  /// route into its own nested stack so pages pushed from inside a
  /// sheet body land within the sheet rather than escaping it.
  ScreenHost? get host => parentHost;

  /// Whether back pops this page: system back, the swipe and Esc. The back
  /// gestures and the system-back state take it as the router renders, so a
  /// page whose `canPop` changes calls [XRouter.pagesChanged].
  bool get canPop => true;

  /// Whether [handleBack] takes back now, as a home's does while it closes a
  /// search. While back goes to a screen that claims it, [XRouter.canPop]
  /// holds, so the framework, not the OS, takes back though nothing pops. The
  /// system-back state reads it as the router renders and after the screen
  /// emits, so a screen whose claim changes emits, where it is a
  /// [Listenable], or calls [XRouter.pagesChanged].
  bool get claimsBack => false;

  /// Custom back handling, asked by system back and by a predictive back as
  /// it commits. Return `true` to consume the back: the page stays, and a
  /// predictive back springs it back. On Android 13 and later the OS takes
  /// back that would pop nothing, unless [claimsBack] holds.
  bool handleBack() => false;

  /// Called after the page is pushed onto the router.
  void onPush() {}

  /// Called when this screen becomes the topmost visible screen in the
  /// router. Fires once after push, and again whenever it becomes topmost
  /// after a screen above it pops or hides, or its shell shows it. Always
  /// paired with a later [onInactive].
  void onActive() {}

  /// Called when another screen is pushed on top, when its shell hides it,
  /// or right before this one is popped. Mirror of [onActive].
  void onInactive() {}

  // === pop lifecycle ===

  /// Whether this page has been popped (explicitly removed).
  bool popped = false;

  /// Set by the router when pushing. Called during [pop] to remove the page
  /// from the router stack and notify the delegate.
  VoidCallback? detach;

  /// Set by the router when pushing. Called from [onRemoved] after the exit
  /// animation completes for final cleanup (disposal).
  VoidCallback? removed;

  Completer<T?>? _completer;

  /// A future that completes with the result when the page is popped.
  Future<T?> get future {
    _completer ??= Completer<T?>();
    return _completer!.future;
  }

  /// Remove this page. Marks as popped, detaches from the router,
  /// and completes the [future] with [result].
  void pop([T? result]) {
    popped = true;
    onDetach();
    if (_completer?.isCompleted != true) {
      _completer?.complete(result);
    }
  }

  /// Called during [pop] before the future is completed.
  /// Override for cleanup that must happen before the exit animation.
  @mustCallSuper
  void onDetach() {
    detach?.call();
    detach = null;
  }

  /// Called after the exit animation completes and the page is fully removed.
  /// Override for cleanup that should happen after the page is off screen.
  @mustCallSuper
  void onRemoved() {
    if (popped) {
      removed?.call();
      removed = null;
    }
  }
}
