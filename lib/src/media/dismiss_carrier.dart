import 'package:ux/src/media/timing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Drag-to-dismiss carrier. Tracks vertical drag from rest; on release
/// dismisses (when distance > viewport.h/4 or velocity > 1.0 px/ms) or
/// snaps back (`kGalleryCustomSpring`).
class DismissCarrier extends StatefulWidget {
  /// Creates the carrier of [child].
  const DismissCarrier({
    super.key,
    required this.child,
    this.dragOffset,
    this.onDismissCommitted,
    this.blocked,
  });

  /// The gallery shell (or any widget) to wrap.
  final Widget child;

  /// Optional notifier for external observers (chrome / dim-fade math).
  /// Updated continuously during drag and during snap-back.
  final ValueNotifier<double>? dragOffset;

  /// Called when release commits a dismiss. Hosts wire to `screen.pop()`.
  final VoidCallback? onDismissCommitted;

  /// When true, drag handlers detach so the gesture falls through to the
  /// inner zoomable.
  final ValueListenable<bool>? blocked;

  @override
  State<DismissCarrier> createState() => DismissCarrierState();
}

/// Public state — the shell forwards inner-zoom past-Y drags into here
/// directly, bypassing the carrier's [GestureDetector] (which may be
/// disabled via [DismissCarrier.blocked]).
class DismissCarrierState extends State<DismissCarrier>
    with SingleTickerProviderStateMixin {
  /// Vertical drag from rest, in logical pixels. Positive = dragged down.
  /// Unbounded so it can be driven both manually and by a [Simulation].
  late final AnimationController _drag;

  bool _dragging = false;

  /// Apply [dy] (positive = pulled down) from an external driver. Auto-
  /// starts the drag and stops any in-flight snap-back.
  void applyExternalDrag(double dy) {
    if (!_dragging) {
      _dragging = true;
      if (_drag.isAnimating) _drag.stop();
    }
    _drag.value = _drag.value + dy;
  }

  /// End an external drag with [velocity] (px/s). Evaluates
  /// dismiss-vs-snap-back identically to the carrier's own release.
  void commitExternalDragEnd(double velocity) {
    if (!_dragging) return;
    _dragging = false;
    final viewport = MediaQuery.sizeOf(context);
    final distanceThreshold = viewport.height / 4;
    final shouldDismiss =
        velocity.abs() > kGalleryDismissVelocity ||
        _drag.value.abs() > distanceThreshold;
    if (shouldDismiss) {
      _commitDismiss();
    } else {
      _animateSnapBack(velocity);
    }
  }

  @override
  void initState() {
    super.initState();
    _drag = AnimationController.unbounded(vsync: this)
      ..addListener(_emitDragOffset);
  }

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _emitDragOffset() {
    widget.dragOffset?.value = _drag.value;
  }

  /// Number of pointers currently down on the gesture surface. Tracked
  /// via a passive [Listener] so the gesture arena's drag claim is
  /// unaffected — we just GATE the drag handlers on the count.
  /// Telegram parity: dismiss is single-finger only; once a second
  /// pointer joins, abort any in-flight drag (snap back) and ignore
  /// subsequent updates until all fingers lift.
  int _activePointerCount = 0;
  bool get _isMultiTouch => _activePointerCount > 1;

  void _onPointerDown(PointerDownEvent _) {
    _activePointerCount++;
    if (_isMultiTouch && _dragging) {
      // 2nd finger landed mid-drag → snap back, no dismiss.
      _dragging = false;
      _animateSnapBack(0.0);
    }
  }

  void _onPointerUp(PointerUpEvent _) {
    if (_activePointerCount > 0) _activePointerCount--;
  }

  void _onPointerCancel(PointerCancelEvent _) {
    if (_activePointerCount > 0) _activePointerCount--;
  }

  void _onPanStart(DragStartDetails details) {
    if (_isMultiTouch) return;
    _dragging = true;
    if (_drag.isAnimating) {
      _drag.stop();
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    if (_isMultiTouch) {
      // 2nd finger arrived during the drag — the pointer-down handler
      // already snapped back; just stop accumulating updates.
      return;
    }
    _drag.value = _drag.value + details.delta.dy;
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final velocity = details.velocity.pixelsPerSecond.dy;
    final viewport = MediaQuery.sizeOf(context);
    final distanceThreshold = viewport.height / 4;
    final shouldDismiss =
        velocity.abs() > kGalleryDismissVelocity ||
        _drag.value.abs() > distanceThreshold;
    if (shouldDismiss) {
      _commitDismiss();
    } else {
      _animateSnapBack(velocity);
    }
  }

  void _onPanCancel() {
    if (!_dragging) return;
    _dragging = false;
    _animateSnapBack(0.0);
  }

  void _animateSnapBack(double velocity) {
    final sim = SpringSimulation(
      kGalleryCustomSpring,
      _drag.value,
      0.0,
      velocity,
    );
    _drag.animateWith(sim);
  }

  void _commitDismiss() {
    widget.onDismissCommitted?.call();
  }

  @override
  Widget build(BuildContext context) {
    final translated = AnimatedBuilder(
      animation: _drag,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _drag.value),
          child: child,
        );
      },
      child: widget.child,
    );
    final blocked = widget.blocked;
    if (blocked == null) {
      return _detector(child: translated, enabled: true);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: blocked,
      builder: (context, isBlocked, child) {
        if (isBlocked && _dragging) {
          _dragging = false;
          _animateSnapBack(0.0);
        }
        return _detector(child: child!, enabled: !isBlocked);
      },
      child: translated,
    );
  }

  Widget _detector({required Widget child, required bool enabled}) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      // Track pointer count passively — informs `_isMultiTouch` so the
      // drag handlers can gate themselves without fighting the gesture
      // arena. Listener observes events without claiming them.
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: enabled
            ? <Type, GestureRecognizerFactory>{
                _AxisLockedVerticalDragRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _AxisLockedVerticalDragRecognizer
                    >(() => _AxisLockedVerticalDragRecognizer(), (
                      _AxisLockedVerticalDragRecognizer instance,
                    ) {
                      instance
                        ..onStart = _onPanStart
                        ..onUpdate = _onPanUpdate
                        ..onEnd = _onPanEnd
                        ..onCancel = _onPanCancel;
                    }),
              }
            : const <Type, GestureRecognizerFactory>{},
        child: child,
      ),
    );
  }

  /// The current drag offset.
  @visibleForTesting
  double get dragValueForTest => _drag.value;

  /// Moves the drag offset by [dy].
  @visibleForTesting
  void simulateDragForTest({required double dy}) {
    _drag.value = _drag.value + dy;
  }

  /// Ends a drag at [velocity] pixels per second.
  @visibleForTesting
  void simulateReleaseForTest({required double velocity}) {
    _onPanStart(DragStartDetails(globalPosition: Offset.zero));
    _onPanEnd(
      DragEndDetails(velocity: Velocity(pixelsPerSecond: Offset(0, velocity))),
    );
  }
}

/// Vertical drag recognizer that fails itself once horizontal motion exceeds
/// [kGalleryDismissXSlop] and dominates the vertical component, ceding the
/// arena to the pager. Mirrors `SwipeToDismissGestureRecognizer.swift:84-104`.
class _AxisLockedVerticalDragRecognizer extends VerticalDragGestureRecognizer {
  Offset _accumulated = Offset.zero;
  bool _resolvedRejected = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _accumulated = Offset.zero;
    _resolvedRejected = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_resolvedRejected && event is PointerMoveEvent) {
      _accumulated += event.localDelta;
      final dx = _accumulated.dx.abs();
      final dy = _accumulated.dy.abs();
      if (dx > kGalleryDismissXSlop && dx >= dy) {
        _resolvedRejected = true;
        resolve(GestureDisposition.rejected);
        return;
      }
    }
    super.handleEvent(event);
  }
}
