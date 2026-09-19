import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

const Duration _kSheetAnimation = Duration(milliseconds: 300);

typedef _SheetUserOffsetGate = bool Function(
  ScrollMetrics position,
  double offset,
);

/// Controller for coordinating scroll views with a [Sheet].
///
/// Child scroll views should register their `ScrollController` using
/// [attach] when they become active and [detach] when they're no longer
/// active. This lets the sheet coordinate gestures with the active
/// scroll view (so e.g. dragging down on a list with nothing left to
/// reveal moves the sheet down rather than overscrolling the list).
///
/// Use [physics] on the active scroll view so user-input scroll is
/// blocked while the sheet is mid-drag.
class SheetController {
  ScrollController? _activeScrollController;
  Object? _userOffsetGateOwner;
  _SheetUserOffsetGate? _userOffsetGate;

  /// The registered scroll view, or `null` while none is attached.
  ScrollController? get activeScrollController => _activeScrollController;

  /// Whether scrolling should be enabled for the active scroll view.
  /// Sheet sets this to false while it consumes the drag itself.
  bool scrollEnabled = true;

  /// Physics to hand the active scroll view so it yields while the sheet
  /// is consuming the gesture.
  ScrollPhysics get physics => SheetScrollPhysics(controller: this);

  void _registerUserOffsetGate(
    Object owner,
    _SheetUserOffsetGate gate,
  ) {
    _userOffsetGateOwner = owner;
    _userOffsetGate = gate;
  }

  void _unregisterUserOffsetGate(Object owner) {
    if (!identical(_userOffsetGateOwner, owner)) return;
    _userOffsetGateOwner = null;
    _userOffsetGate = null;
  }

  Future<void> Function()? _dismissCallback;

  /// Animate the sheet offscreen. Returns a future that completes
  /// when the dismissal is done.
  Future<void> animateDismiss() async {
    await _dismissCallback?.call();
  }

  /// Normalized position when dismiss was triggered (0 = offscreen,
  /// 1 = collapsed). Used by host route adapters to start a
  /// physics-based exit animation from the gesture's current position.
  double? dismissPosition;

  /// Normalized velocity (units / second) when dismiss was triggered.
  double? dismissVelocity;

  /// Records the gesture state a host route adapter continues the exit
  /// animation from.
  void setDismissState(double position, double velocity) {
    dismissPosition = position;
    dismissVelocity = velocity;
  }

  /// Drops the recorded gesture state, so an exit starts from rest.
  void clearDismissState() {
    dismissPosition = null;
    dismissVelocity = null;
  }

  /// Read by host route adapters to fetch the sheet's current
  /// normalized position when `pop()` is called directly (no gesture).
  double Function()? getCurrentPosition;

  /// Set by the host's dismiss adapter — tells the Sheet to defer to
  /// the route animation for position rather than its own animator.
  bool isPopping = false;

  /// Makes [controller] the scroll view the sheet coordinates with.
  void attach(ScrollController controller) {
    _activeScrollController = controller;
  }

  /// Unregisters [controller], if it is the active one.
  void detach(ScrollController controller) {
    if (_activeScrollController == controller) {
      _activeScrollController = null;
    }
  }

  /// Offset of the active scroll view; `0` when none is attached or it has
  /// no clients.
  double get scrollOffset {
    final sc = _activeScrollController;
    if (sc == null || !sc.hasClients) return 0.0;
    return sc.offset;
  }
}

/// Scroll physics that coordinate with a [SheetController].
/// When `controller.scrollEnabled` is false, scrolling is blocked
/// (the sheet itself is consuming the gesture). Clamping behavior —
/// no overscroll bounce.
class SheetScrollPhysics extends ScrollPhysics {
  /// Binds the controller whose gesture state gates scrolling.
  const SheetScrollPhysics({required this.controller, super.parent});

  /// The sheet whose drag state these physics defer to.
  final SheetController controller;

  @override
  SheetScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return SheetScrollPhysics(
      controller: controller,
      parent: buildParent(ancestor),
    );
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (!(controller._userOffsetGate?.call(position, offset) ?? true) ||
        !controller.scrollEnabled) {
      return 0.0;
    }
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (!controller.scrollEnabled) return value - position.pixels;
    if (value < position.minScrollExtent) {
      return value - position.minScrollExtent;
    }
    if (value > position.maxScrollExtent) {
      return value - position.maxScrollExtent;
    }
    return 0.0;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (!controller.scrollEnabled) return null;
    return super.createBallisticSimulation(position, velocity);
  }
}

/// Bottom sheet with telegram-style behavior:
/// - Entry: slides up from the bottom edge to the collapsed extent.
/// - Drag down past threshold → calls [onDismiss] (host pops; reverse
///   animation plays).
/// - Drag up from collapsed → expands to fullscreen.
/// - Drag down with the attached list at its edge → collapses.
/// - Spring physics for snap (telegram damping ≈ 124 / 0.45s).
/// - Scroll coordination via [SheetController]: down-drags scroll an
///   attached list with room from any snap, while up-drags expand a
///   non-expanded sheet before scrolling the list.
///
/// When [routeAnimation] is provided, the Sheet defers to it for the
/// entry / exit position so the host's `Route` (or a `Screen`)
/// can hero-animate. With null [routeAnimation] the Sheet self-manages
/// entry / exit via its own [AnimationController].
class Sheet extends StatefulWidget {
  /// Binds the sheet's content, its extents, and how it is dismissed.
  const Sheet({
    super.key,
    required this.child,
    this.controller,
    this.routeAnimation,
    this.collapsedExtent = 0.6,
    this.isFullSize = false,
    this.isDismissible = true,
    this.onDismiss,
    this.barrierColor = Colors.black54,
    this.backgroundColor,
    this.borderRadius = 16.0,
  });

  /// Content the sheet carries.
  final Widget child;

  /// Coordinates the sheet with the content's active scroll view. Without
  /// one the sheet drags on every gesture it receives.
  final SheetController? controller;

  /// When provided, the sheet position is driven by this animation.
  /// 0.0 = offscreen (bottom), 1.0 = collapsed.
  final Animation<double>? routeAnimation;

  /// Fraction of the screen the sheet covers when collapsed.
  final double collapsedExtent;

  /// Whether the sheet opens expanded to fullscreen rather than collapsed.
  final bool isFullSize;

  /// Whether a drag past the threshold, or a barrier tap, dismisses.
  final bool isDismissible;

  /// Called when the sheet asks to go away; the host performs the pop.
  final VoidCallback? onDismiss;

  /// Scrim painted behind the sheet, at full opacity when collapsed.
  final Color barrierColor;

  /// Sheet surface colour; the theme's canvas colour when omitted.
  final Color? backgroundColor;

  /// Corner radius of the sheet (top corners always; bottom corners
  /// shrink toward 0 as the sheet expands).
  final double borderRadius;

  @override
  State<Sheet> createState() => SheetState();
}

/// Drag, snap, and dismiss state of a [Sheet].
class SheetState extends State<Sheet> with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  bool get _hasRouteAnimation => widget.routeAnimation != null;

  bool _isExpanded = false;

  /// Visual offset: 0 at rest, negative when dragged down (sheet smaller).
  double _boundsOriginY = 0.0;

  /// Animated top during internal expand/collapse transitions.
  /// When null, position is computed from state instead.
  double? _animatedTop;

  // Pan gesture state (mirrors telegram's panGestureArguments).
  double? _panTopInset;

  /// Drag travel applied to the sheet in the current gesture, measured
  /// from the snap the gesture started at. Negative expands.
  double _panOffset = 0.0;

  /// Whether the pointer went down on sheet chrome rather than on the
  /// attached scrollable — such gestures belong to the sheet.
  bool _chromeOrigin = false;

  /// Scroll pixels of the attached list at the previous pan update.
  double _listPixels = 0.0;

  SheetController? _gestureController;

  bool _expandedDuringPan = false;

  /// Last gesture velocity normalized to "screen heights / second".
  double _lastNormalizedVelocity = 0.0;

  bool _isDismissing = false;

  /// Whether the sheet is sliding away. It takes no touches then and drops
  /// the gesture in flight, so the slide runs to its end.
  bool _leaving = false;

  double get _screenHeight => MediaQuery.sizeOf(context).height;

  /// Distance from screen top to the sheet's collapsed edge.
  double get _edgeTopInset => _screenHeight * (1.0 - widget.collapsedExtent);

  double get _restTopOffset => _isExpanded ? 0.0 : _edgeTopInset;

  /// Position from route animation (offscreen → collapsed).
  /// Maps animation 0→1 to screenHeight→edgeTopInset.
  double? get _routeAnimatedTop {
    final anim = widget.routeAnimation;
    if (anim == null) return null;
    return _screenHeight + (_edgeTopInset - _screenHeight) * anim.value;
  }

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this);

    widget.controller?._dismissCallback = _animateDismiss;
    widget.controller?.getCurrentPosition = _getCurrentNormalizedPosition;

    widget.routeAnimation?.addListener(_onRouteAnimationUpdate);

    if (!_hasRouteAnimation) {
      _animatedTop = double.infinity; // start offscreen
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _animateToCollapsed();
      });
    }
  }

  void _onRouteAnimationUpdate() {
    if (mounted) setState(() {});
  }

  /// Current normalized position, used by the host's route adapter
  /// to drive a physics-based exit animation.
  double _getCurrentNormalizedPosition() {
    final currentTop = _animatedTop ?? (_restTopOffset - _boundsOriginY);
    return ((_screenHeight - currentTop) / (_screenHeight - _edgeTopInset))
        .clamp(0.0, double.infinity);
  }

  @override
  void dispose() {
    _releaseUserOffsetGate();
    widget.routeAnimation?.removeListener(_onRouteAnimationUpdate);
    widget.controller?._dismissCallback = null;
    widget.controller?.getCurrentPosition = null;
    _animController.dispose();
    super.dispose();
  }

  Future<void> _animateDismiss() {
    if (_hasRouteAnimation) {
      widget.onDismiss?.call();
      return Future<void>.value();
    }
    return _playDismissAnimation();
  }

  /// Slide the sheet offscreen and pin it there. Pure visual — no
  /// [widget.onDismiss] notification, no [_isDismissing] flag.
  /// Callers ([_dismiss] for gesture / backdrop, [_animateDismiss]
  /// for [SheetController.animateDismiss]) layer their own pre- /
  /// post-actions on top.
  ///
  /// The trailing pin to `_screenHeight` defends against the tail
  /// frame between the animator's own `_animatedTop = null` cleanup
  /// and the caller's pop / unmount — without it that frame paints
  /// at `_restTopOffset` (the pre-dismiss collapsed / expanded
  /// position) and flashes.
  Future<void> _playDismissAnimation() {
    setState(() => _leaving = true);
    _onPanCancel();
    return _animateWithEaseInOut(
      targetTop: _screenHeight,
      duration: _kSheetAnimation,
    ).then((_) {
      if (mounted) setState(() => _animatedTop = _screenHeight);
    });
  }

  // ── Drag arbitration ───────────────────────────────────────────────

  static const double _kEdgeEpsilon = 1.0;

  ScrollPosition? get _listPosition {
    final controller = widget.controller?.activeScrollController;
    if (controller == null || !controller.hasClients) return null;
    return controller.position;
  }

  /// Sign relating downward drag distance to scroll-pixel movement: a
  /// reversed list scrolls toward [ScrollPosition.maxScrollExtent] when
  /// the finger goes down, a forward one toward its minimum.
  double _dragToScrollSign(ScrollPosition position) =>
      axisDirectionIsReversed(position.axisDirection) ? 1.0 : -1.0;

  /// Whether the attached list has content left to reveal in the
  /// direction a drag of [dragDelta] pushes it.
  bool _listHasRoom(double dragDelta) {
    final position = _listPosition;
    if (position == null) return false;
    if (position.maxScrollExtent <= position.minScrollExtent) return false;
    final scrollDelta = dragDelta * _dragToScrollSign(position);
    if (scrollDelta > 0) {
      return position.pixels < position.maxScrollExtent - _kEdgeEpsilon;
    }
    if (scrollDelta < 0) {
      return position.pixels > position.minScrollExtent + _kEdgeEpsilon;
    }
    return false;
  }

  /// Whether the attached list, rather than the sheet, consumes a drag
  /// of [dragDelta] logical pixels.
  bool _listOwnsDrag(double dragDelta) {
    if (_chromeOrigin) return false;
    if (!_sheetAtSnap) return false;
    if (dragDelta < 0 && !_isExpanded && !_expandedDuringPan) return false;
    return _listHasRoom(dragDelta);
  }

  bool _allowsListUserOffset(ScrollMetrics position, double offset) {
    return _listOwnsDrag(
      axisDirectionIsReversed(position.axisDirection) ? -offset : offset,
    );
  }

  /// Drag distance the attached list consumed since the previous pan
  /// update.
  double _drainListMovement() {
    final position = _listPosition;
    if (position == null) return 0.0;
    final moved = position.pixels - _listPixels;
    _listPixels = position.pixels;
    return moved * _dragToScrollSign(position);
  }

  /// Whether [globalPosition] lands on sheet chrome rather than on the
  /// attached scrollable.
  bool _isOnChrome(Offset globalPosition) {
    final renderObject = _listPosition?.context.storageContext
        .findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return true;
    final origin = renderObject.localToGlobal(Offset.zero);
    return !(origin & renderObject.size).contains(globalPosition);
  }

  /// The sheet cannot travel above the expanded snap.
  double get _panLowerBound => _isExpanded ? 0.0 : -_edgeTopInset;

  bool get _sheetAtSnap => _panOffset == 0.0 || _panOffset == _panLowerBound;

  /// Applies [delta] logical pixels of downward drag to the sheet. The
  /// sheet stops at the snap it returns to, so the drag that follows is
  /// arbitrated afresh.
  void _moveSheet(double delta) {
    final previous = _panOffset;
    final target = previous + delta;
    _panOffset = previous != 0.0 && target.sign != previous.sign
        ? 0.0
        : max(_panLowerBound, target);

    widget.controller?.scrollEnabled = _panOffset == previous;
    if (_panOffset == previous) return;

    if (_isExpanded) {
      setState(() => _boundsOriginY = -_panOffset);
    } else if (_panOffset < 0) {
      _expandedDuringPan = _panOffset == _panLowerBound;
      setState(() => _animatedTop = _edgeTopInset + _panOffset);
    } else {
      _expandedDuringPan = false;
      setState(() {
        _animatedTop = null;
        _boundsOriginY = -_panOffset;
      });
    }
  }

  // ── Pan handlers ───────────────────────────────────────────────────

  /// Latches the origin from the pointer that opens the gesture. Runs for
  /// every pointer-down on the sheet, including ones landing mid-drag.
  void _latchGestureOrigin(Offset globalPosition) {
    if (_panTopInset != null) return;
    _chromeOrigin = _isOnChrome(globalPosition);
  }

  void _onPanStart(DragStartDetails details) {
    if (_leaving) return;
    _animController.stop();
    _panTopInset = _isExpanded ? 0.0 : _edgeTopInset;
    _panOffset = 0.0;
    _expandedDuringPan = false;
    _listPixels = _listPosition?.pixels ?? 0.0;
    _gestureController = widget.controller;
    _gestureController?._registerUserOffsetGate(this, _allowsListUserOffset);

    widget.controller?.scrollEnabled = !_chromeOrigin;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final topInset = _panTopInset;
    if (topInset == null) return;

    final delta = details.delta.dy;
    final consumedByList = _drainListMovement();

    if (_listOwnsDrag(delta)) {
      widget.controller?.scrollEnabled = true;
      return;
    }
    _moveSheet(delta - consumedByList);
  }

  // ── Dismiss decision ───────────────────────────────────────────────

  /// Seconds of coast the release velocity is projected over to find the
  /// position the gesture is headed for.
  static const double _kProjectionHorizon = 0.25;

  /// Distance past the collapsed edge a projected landing dismisses at.
  static const double _kDismissLanding = 60.0;

  static const double _kFullSizeDismissLanding = 180.0;

  /// Upward release speed (pixels / second) that reads as a pull back:
  /// the sheet returns however far down it sits.
  static const double _kPullBackVelocity = 50.0;

  /// Downward release speed (pixels / second) that dismisses an expanded
  /// sheet whatever its projected landing.
  static const double _kExpandedFlingVelocity = 1800.0;

  /// Whether a release at [currentTop] carrying [velocity] pixels / second
  /// lands far enough down the screen to dismiss the sheet.
  bool _releaseDismisses({
    required double currentTop,
    required double velocity,
    required bool fromExpanded,
    required bool listAbsorbsDown,
  }) {
    if (!widget.isDismissible) return false;

    if (fromExpanded && !listAbsorbsDown && velocity > _kExpandedFlingVelocity) {
      return true;
    }
    if (velocity < -_kPullBackVelocity) return false;

    final landing = currentTop + velocity * _kProjectionHorizon;
    final threshold =
        widget.isFullSize ? _kFullSizeDismissLanding : _kDismissLanding;
    return landing > _edgeTopInset + threshold;
  }

  void _onPanEnd(DragEndDetails details) {
    final topInset = _panTopInset;
    if (topInset == null) return;

    _panTopInset = null;
    _panOffset = 0.0;
    widget.controller?.scrollEnabled = true;
    _releaseUserOffsetGate();

    final listAbsorbsDown = _listOwnsDrag(1.0);
    var velocity = details.velocity.pixelsPerSecond.dy;

    if (listAbsorbsDown && velocity > 0.0) {
      velocity = 0.0;
    }

    _lastNormalizedVelocity = -velocity / _screenHeight;

    final edgeTopInset = _edgeTopInset;
    final currentTop = _animatedTop ?? (_restTopOffset - _boundsOriginY);

    if (_releaseDismisses(
      currentTop: currentTop,
      velocity: velocity,
      fromExpanded: _isExpanded || _expandedDuringPan,
      listAbsorbsDown: listAbsorbsDown,
    )) {
      _expandedDuringPan = false;
      _dismiss();
      return;
    }

    if (_isExpanded || _expandedDuringPan) {
      if ((velocity > 300.0 || currentTop > edgeTopInset / 2.0) &&
          !widget.isFullSize) {
        // COLLAPSE.
        final fromTop = currentTop;
        _animatedTop = fromTop;
        _boundsOriginY = 0.0;
        _isExpanded = false;
        _expandedDuringPan = false;

        final initialVelocity =
            velocity.abs() / max(1.0, (edgeTopInset - fromTop).abs());
        _animateWithSpring(
          targetTop: edgeTopInset,
          initialVelocity: initialVelocity,
          fromTop: fromTop,
        );
      } else {
        // STAY EXPANDED.
        _animatedTop = currentTop;
        _boundsOriginY = 0.0;
        _isExpanded = true;
        _expandedDuringPan = false;
        _animateWithEaseInOut(targetTop: 0.0, fromTop: currentTop);
      }
    } else {
      if (velocity < -300.0 || currentTop < edgeTopInset / 2.0) {
        // EXPAND.
        final fromTop = currentTop;
        _animatedTop = fromTop;
        _boundsOriginY = 0.0;
        _isExpanded = true;

        final initialVelocity = velocity.abs() / max(1.0, fromTop.abs());
        _animateWithSpring(
          targetTop: 0.0,
          initialVelocity: initialVelocity,
          fromTop: fromTop,
        );
      } else {
        // STAY COLLAPSED.
        _animatedTop = currentTop;
        _boundsOriginY = 0.0;
        _animateWithEaseInOut(targetTop: edgeTopInset, fromTop: currentTop);
      }
    }
  }

  void _onPanCancel() {
    _panTopInset = null;
    widget.controller?.scrollEnabled = true;
    _releaseUserOffsetGate();
  }

  void _releaseUserOffsetGate() {
    _gestureController?._unregisterUserOffsetGate(this);
    _gestureController = null;
  }

  // ── Animations ─────────────────────────────────────────────────────

  void _animateToCollapsed() {
    _isExpanded = false;
    _animatedTop = _screenHeight;
    _boundsOriginY = 0.0;
    _animateWithEaseInOut(targetTop: _edgeTopInset, fromOffscreen: true);
  }

  void _dismiss() {
    if (_hasRouteAnimation) {
      final currentTop = _animatedTop ?? (_restTopOffset - _boundsOriginY);
      final normalizedPosition =
          ((_screenHeight - currentTop) / (_screenHeight - _edgeTopInset))
              .clamp(0.0, double.infinity);
      widget.controller
          ?.setDismissState(normalizedPosition, _lastNormalizedVelocity);
      _isDismissing = true;
      _isExpanded = false;
      _boundsOriginY = 0.0;
      _animatedTop = null;
      widget.onDismiss?.call();
    } else {
      _isDismissing = true;
      _playDismissAnimation().then((_) {
        if (mounted) widget.onDismiss?.call();
      });
    }
  }

  /// Spring animation tuned to feel like telegram's damping ≈ 124 / 0.45s.
  Future<void> _animateWithSpring({
    required double targetTop,
    required double initialVelocity,
    double? fromTop,
  }) {
    _animController.stop();

    final currentTop = fromTop ?? (_restTopOffset - _boundsOriginY);
    _animatedTop = currentTop;
    _boundsOriginY = 0.0;

    const spring = SpringDescription(mass: 1.0, stiffness: 500.0, damping: 30.0);
    final springVelocity =
        initialVelocity * (targetTop - currentTop).sign;
    final normalizedSpring = SpringSimulation(
      spring,
      0.0,
      1.0,
      springVelocity / max(1e-3, (targetTop - currentTop).abs()),
    );

    late void Function() listener;
    listener = () {
      final t = _animController.value;
      final newTop = currentTop + (targetTop - currentTop) * t;
      if (mounted) {
        setState(() => _animatedTop = newTop.clamp(0.0, _screenHeight));
      }
    };

    _animController.addListener(listener);
    return _animController.animateWith(normalizedSpring).then((_) {
      _animController.removeListener(listener);
      if (mounted) setState(() => _animatedTop = null);
    });
  }

  /// EaseInOut animation, telegram default 0.3s.
  Future<void> _animateWithEaseInOut({
    required double targetTop,
    Duration duration = _kSheetAnimation,
    bool fromOffscreen = false,
    double? fromTop,
  }) {
    _animController.stop();

    final startTop = fromOffscreen
        ? _screenHeight
        : (fromTop ?? (_restTopOffset - _boundsOriginY));
    _animatedTop = startTop;
    _boundsOriginY = 0.0;

    late void Function() listener;
    listener = () {
      final t = Curves.easeInOut.transform(_animController.value);
      if (mounted) {
        setState(() => _animatedTop = startTop + (targetTop - startTop) * t);
      }
    };

    _animController.duration = duration;
    _animController.addListener(listener);
    _animController.forward(from: 0.0);

    return _animController.animateTo(1.0).then((_) {
      _animController.removeListener(listener);
      if (mounted) setState(() => _animatedTop = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final screenHeight = screenSize.height;
    final screenWidth = screenSize.width;

    final isPopping = widget.controller?.isPopping ?? false;
    final double topOffset;
    if ((_isDismissing || isPopping) && _hasRouteAnimation) {
      topOffset = (_routeAnimatedTop ?? _restTopOffset).clamp(0.0, screenHeight);
    } else if (_animatedTop != null) {
      topOffset = _animatedTop!.clamp(0.0, screenHeight);
    } else if (_hasRouteAnimation && !_isExpanded && _boundsOriginY == 0.0) {
      topOffset = (_routeAnimatedTop ?? _restTopOffset).clamp(0.0, screenHeight);
    } else {
      topOffset = (_restTopOffset - _boundsOriginY).clamp(0.0, screenHeight);
    }

    final safeAreaTop = MediaQuery.paddingOf(context).top;
    final edgeTopInset = _edgeTopInset;
    final clampedTopOffset = topOffset.clamp(safeAreaTop, screenHeight);

    final expansionRange = edgeTopInset - safeAreaTop;
    final expansionProgress = expansionRange > 0
        ? ((edgeTopInset - clampedTopOffset) / expansionRange).clamp(0.0, 1.0)
        : 0.0;

    const collapsedPadding = 6.0;
    final sheetPadding = collapsedPadding * (1.0 - expansionProgress);

    final collapsedHeight = screenHeight - edgeTopInset;
    final cornerRadius =
        (widget.borderRadius - sheetPadding).clamp(0.0, widget.borderRadius);

    final barrierProgress =
        (1.0 - clampedTopOffset / edgeTopInset).clamp(0.0, 1.0);

    final sheetLeft = sheetPadding;
    final sheetTop = clampedTopOffset;
    final sheetWidth = screenWidth - sheetPadding * 2;
    final sheetHeight =
        max(collapsedHeight, screenHeight - clampedTopOffset) - sheetPadding;

    final animValue = widget.routeAnimation?.value ?? 1.0;

    final sheet = Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.isDismissible && !_leaving ? _dismiss : null,
            behavior: HitTestBehavior.opaque,
            child: ColoredBox(
              color: widget.barrierColor.withValues(
                alpha: widget.barrierColor.a * barrierProgress * animValue,
              ),
            ),
          ),
        ),
        Positioned(
          left: sheetLeft,
          top: sheetTop,
          width: sheetWidth,
          height: sheetHeight,
          child: RawGestureDetector(
            gestures: <Type, GestureRecognizerFactory<GestureRecognizer>>{
              _SheetPanRecognizer:
                  GestureRecognizerFactoryWithHandlers<_SheetPanRecognizer>(
                _SheetPanRecognizer.new,
                (r) => r
                  ..onPointerDown = _latchGestureOrigin
                  ..onStart = _onPanStart
                  ..onUpdate = _onPanUpdate
                  ..onEnd = _onPanEnd
                  ..onCancel = _onPanCancel,
              ),
            },
            child: Material(
              color: widget.backgroundColor ??
                  Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(widget.borderRadius),
                bottom: Radius.circular(cornerRadius),
              ),
              clipBehavior: Clip.hardEdge,
              elevation: 8,
              child: Column(
                children: [
                  const SheetThumb(),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    return IgnorePointer(ignoring: _leaving, child: sheet);
  }
}

/// Vertical-only pan recognizer that always wins the arena. Lets a
/// drag-to-expand on the sheet beat sibling recognizers (e.g. a tap
/// recognizer in the title bar).
class _SheetPanRecognizer extends VerticalDragGestureRecognizer {
  /// Reports the global position of each pointer-down on the sheet,
  /// before the drag is recognized and the touch slop shifts it.
  ValueChanged<Offset>? onPointerDown;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    onPointerDown?.call(event.position);
    super.addAllowedPointer(event);
  }

  @override
  void rejectGesture(int pointer) => acceptGesture(pointer);
}

/// Centered pill drag-handle. Default for the top edge of a [Sheet].
class SheetThumb extends StatelessWidget {
  /// Creates a drag handle.
  const SheetThumb({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          height: 5,
          width: 36,
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2.5),
          ),
        ),
      ),
    );
  }
}
