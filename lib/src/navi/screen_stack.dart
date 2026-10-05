import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;

import 'package:ux/src/core/functional.dart';
import 'package:ux/src/navi/hero.dart';
import 'package:ux/src/navi/screen.dart';

/// A declarative screen stack with animated transitions.
///
/// Two slots with different reconciliation contracts:
///
/// - [home] — `Widget.canUpdate`-style match (`runtimeType` +
///   [Screen.key]). A fresh instance of the same type/key updates the
///   home slot in place; State below is preserved. Different type or
///   key tears it down. Home never animates in/out, never pops.
/// - [stack] — `==`-based diff. Equal Screens reorder, distinct
///   Screens get new slots with enter transitions and pop animations.
class ScreenStack extends StatefulWidget {
  /// Binds the screen in the home slot and the screens stacked above it.
  const ScreenStack({
    super.key,
    required this.home,
    this.stack = const [],
    this.hidden = const {},
    this.beside = const {},
    this.place,
    this.onRemoved,
  });

  /// The screen at the bottom, matched by type and key.
  final Screen home;

  /// Screens above [home], bottom to top, matched by `==`.
  final List<Screen> stack;

  /// Screens of [stack] kept offstage: mounted with their State, but
  /// unpainted, out of hit testing and focus, their tickers muted. One
  /// hides and shows again at once, and leaves without an exit transition.
  final Set<Screen> hidden;

  /// Screens of [stack] that sit beside the screen under them instead of
  /// covering it. The stack hands one no focus as it enters, and focus
  /// inside one as it hides or leaves goes back to the screen it sits
  /// beside, whose Tab traversal it shares. It takes no back gesture.
  final Set<Screen> beside;

  /// Wraps the slot of a screen of [stack] to lay out where it draws. A
  /// leaving slot keeps the wrapper it last had.
  final Widget Function(BuildContext context, Screen screen, Widget slot)?
      place;

  /// Called once a popped screen's exit animation has finished.
  final ValueChanged<Screen>? onRemoved;

  @override
  State<ScreenStack> createState() => ScreenStackState();

  /// The enclosing stack's state. Throws where there is none.
  static ScreenStackState of(BuildContext context) {
    return context.findAncestorStateOfType<ScreenStackState>()!;
  }

  /// The enclosing stack's state, or `null` where there is none.
  static ScreenStackState? maybeOf(BuildContext context) {
    return context.findAncestorStateOfType<ScreenStackState>();
  }
}

/// Slot bookkeeping and transition animations behind a [ScreenStack].
class ScreenStackState extends State<ScreenStack> with TickerProviderStateMixin {
  late ScreenSlot _homeSlot;
  final List<ScreenSlot> _entries = [];

  /// Matches heroes across the screens in this stack and flies them.
  final ScreenHeroController heroController = ScreenHeroController();
  final FocusScopeNode _outerScope = FocusScopeNode(debugLabel: 'ScreenStack');

  bool _canPop = false;
  ScreenSlot? _focusedSlot;

  @override
  void initState() {
    super.initState();
    _homeSlot = _createHomeSlot(widget.home);
    for (final page in widget.stack) {
      _entries.add(_createEntry(page, animated: false));
    }
    _sync();
    _updateCanPop();
    _scheduleTopFocusHandoff();
  }

  void _sync() {
    var under = _homeSlot;
    for (final entry in _entries) {
      if (entry.removing) continue;
      entry.hidden = widget.hidden.contains(entry.page);
      entry.beside = widget.beside.contains(entry.page) ? under : null;
      entry._place = widget.place;
      if (entry._covers) under = entry;
    }
  }

  /// Hand focus to the current top slot's scope on the next frame.
  /// Mirrors what [Navigator] does via `setFirstFocus` on push: without
  /// it, a freshly-pushed page's `autofocus: true` TextField ends up
  /// focused but never becomes the active scope, so the keyboard token
  /// is never consumed and the system keyboard doesn't open.
  void _scheduleTopFocusHandoff() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final top = _topSlot;
      if (top == _focusedSlot) return;
      _focusedSlot = top;
      _outerScope.setFirstFocus(top.focusScope);
    });
  }

  void _updateCanPop() {
    final canPop = _entries.any((e) => e._covers && e.page.canPop);
    if (canPop == _canPop) return;
    _canPop = canPop;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) NavigationNotification(canHandlePop: canPop).dispatch(context);
    });
  }

  @override
  void didUpdateWidget(ScreenStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateHome(oldWidget.home, widget.home);
    _diffStack(oldWidget.stack, widget.stack);
  }

  void _updateHome(Screen oldHome, Screen newHome) {
    if (identical(oldHome, newHome)) return;
    if (oldHome.runtimeType == newHome.runtimeType &&
        oldHome.key == newHome.key) {
      _homeSlot.page = newHome;
      return;
    }
    final old = _homeSlot;
    old.controller.dispose();
    old.focusScope.dispose();
    if (identical(_focusedSlot, old)) _focusedSlot = null;
    _homeSlot = _createHomeSlot(newHome);
    _scheduleTopFocusHandoff();
  }

  void _diffStack(List<Screen> oldStack, List<Screen> newStack) {
    final oldSet = <Screen>{...oldStack};
    final newSet = <Screen>{...newStack};

    final hasChanges = oldStack.length != newStack.length ||
        oldSet.any((p) => !newSet.contains(p)) ||
        newSet.any((p) => !oldSet.contains(p));

    // Snapshot only on actual mutation; otherwise every host-driven
    // rebuild would schedule a post-frame flight check.
    final heroSnapshot = hasChanges ? heroController.snapshot() : null;

    for (final entry in _entries.toList()) {
      if (entry.removing) continue;
      if (!newSet.contains(entry.page)) {
        _removeEntry(entry);
      }
    }

    for (final page in newStack) {
      if (!oldSet.contains(page)) {
        _entries.add(_createEntry(page, animated: true));
      }
    }

    // Reorder to match newStack, keeping removing entries in their
    // original relative position so an exiting child stays above its
    // parent, not behind it.
    final ordered = <ScreenSlot>[];
    for (final page in newStack) {
      ordered.add(_entries.firstWhere((e) => e.page == page && !e.removing));
    }
    final result = <ScreenSlot>[];
    int oi = 0;
    for (final entry in _entries) {
      if (entry.removing) {
        result.add(entry);
      } else if (oi < ordered.length) {
        result.add(ordered[oi++]);
      }
    }
    while (oi < ordered.length) {
      result.add(ordered[oi++]);
    }
    _entries
      ..clear()
      ..addAll(result);

    if (heroSnapshot != null && heroSnapshot.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final topEntry = _entries.lastWhereOrNull((e) => !e.removing);
        if (topEntry == null) return;
        final overlay = Overlay.maybeOf(context);
        if (overlay == null) return;
        heroController.maybeStartFlights(
          before: heroSnapshot,
          animation: topEntry.controller,
          overlay: overlay,
        );
      });
    }

    _sync();
    _updateCanPop();
    _scheduleTopFocusHandoff();
    setState(() {});
  }

  ScreenSlot _createHomeSlot(Screen home) {
    final controller = AnimationController(
      vsync: this,
      duration: Duration.zero,
      value: 1.0,
    );
    return ScreenSlot(page: home, controller: controller);
  }

  ScreenSlot _createEntry(Screen page, {required bool animated}) {
    final controller = AnimationController(
      vsync: this,
      duration: page.transitionDuration,
      value: animated ? 0.0 : 1.0,
    );
    final entry = ScreenSlot(page: page, controller: controller);
    if (animated) controller.forward();
    return entry;
  }

  void _removeEntry(ScreenSlot entry) {
    entry.removing = true;
    final exit =
        entry.hidden ? Future<void>.value() : entry.controller.reverse();
    exit.then((_) {
      if (!mounted) return;
      _entries.remove(entry);
      entry.controller.dispose();
      entry.focusScope.dispose();
      if (_focusedSlot == entry) _focusedSlot = null;
      entry.page.onRemoved();
      widget.onRemoved?.call(entry.page);
      _scheduleTopFocusHandoff();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _homeSlot.controller.dispose();
    _homeSlot.focusScope.dispose();
    for (final entry in _entries) {
      entry.controller.dispose();
      entry.focusScope.dispose();
    }
    _outerScope.dispose();
    super.dispose();
  }

  /// Topmost covering slot — the last pushed entry that covers, if any,
  /// else home. Used for focus handoff.
  ScreenSlot get _topSlot =>
      _entries.lastWhereOrNull((e) => e._covers) ?? _homeSlot;

  Widget _place(BuildContext context, ScreenSlot entry, Widget slot) =>
      entry._place?.call(context, entry.page, slot) ?? slot;

  @override
  Widget build(BuildContext context) {
    final top = _entries.lastWhereOrNull((e) => e._covers);
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            final focus = FocusManager.instance.primaryFocus;
            if (focus != null && focus.context != null &&
                focus.context!.findAncestorWidgetOfExactType<EditableText>() != null) {
              focus.unfocus();
              return null;
            }
            if (top != null && top.page.isModal) {
              top.page.pop();
            }
            return null;
          },
        ),
      },
      child: FocusScope(
        node: _outerScope,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            // Anchored on the slot's GlobalKey so a slot replacement
            // unmounts the old subtree — without it, Flutter would
            // reconcile inner widgets by type and preserve their State.
            KeyedSubtree(key: _homeSlot.key, child: _homeSlot.build(context)),
            for (final entry in _entries)
              _place(
                context,
                entry,
                ScreenBackHandler(
                  key: entry.key,
                  entry: entry,
                  enabled: entry == top && _canPop && entry.page.canPop,
                  onPop: () => entry.page.pop(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A slot in the [ScreenStack] that holds a [Screen] and manages its
/// transition animation.
class ScreenSlot {
  /// Binds the screen to the controller driving its transition.
  ScreenSlot({required this.page, required this.controller});

  /// [animation], the one a slot hands [Screen.buildTransition], on [curve];
  /// while a back gesture drives the slot at [context] it is the gesture's
  /// own progress, and once the gesture lets go it runs [curve] from there to
  /// where the transition settles.
  static Animation<double> curved(
    BuildContext context,
    Animation<double> animation,
    Curve curve,
  ) {
    final slot = context.getInheritedWidgetOfExactType<_SlotScope>()?.slot;
    if (slot == null) return animation.drive(CurveTween(curve: curve));
    return _GestureCurve(animation, curve, slot);
  }

  /// The screen this slot holds; reassigned when an equal screen updates it.
  Screen page;

  /// Drives the enter and exit transitions; 1 when fully on screen.
  final AnimationController controller;

  /// Identity of the slot itself, so reordering moves it rather than
  /// rebuilding it.
  final key = GlobalKey();

  /// Identity of the screen's content below the transition, so the content
  /// keeps its State when the transition changes shape.
  final contentKey = GlobalKey();

  /// Focus scope private to this slot, so a pushed screen starts with a
  /// clean focus state. The outer [ScreenStack] scope calls `setFirstFocus`
  /// on it when the slot becomes top, matching Navigator's per-route scope
  /// handoff. Sharing one scope across slots makes a new screen's
  /// `autofocus: true` field silently no-op — the outgoing screen's focus
  /// still occupies `_focusedChildren` — and without `setFirstFocus` the
  /// keyboard token is never consumed, so no keyboard appears.
  final focusScope = FocusScopeNode();

  /// Whether this slot is playing its exit animation.
  bool removing = false;

  /// The back gesture driving [controller], while one does.
  _BackGesture? _backGesture;

  /// Whether the screen is kept offstage: mounted with its State, but
  /// unpainted, out of hit testing and focus, its tickers muted.
  bool hidden = false;

  /// The slot this one sits beside instead of covering, whose Tab traversal
  /// it shares; null when this one covers the slots under it.
  ScreenSlot? get beside => _beside;
  ScreenSlot? _beside;
  set beside(ScreenSlot? slot) {
    _beside = slot;
    focusScope.traversalEdgeBehavior = slot == null
        ? TraversalEdgeBehavior.closedLoop
        : TraversalEdgeBehavior.parentScope;
  }

  Widget Function(BuildContext context, Screen screen, Widget slot)? _place;

  bool get _covers => !removing && !hidden && beside == null;

  /// Builds the screen under its transition, rebuilding it whenever the
  /// screen itself emits.
  Widget build(BuildContext context) {
    final child = page is Listenable
        ? ListenableBuilder(
            listenable: page as Listenable,
            builder: (context, _) => page.buildPresenter(context),
          )
        : page.buildPresenter(context);
    final focusable = !hidden && !(removing && beside != null);

    return Offstage(
      offstage: hidden,
      child: TickerMode(
        enabled: !hidden,
        child: _SlotScope(
          slot: this,
          child: AnimatedBuilder(
            animation: controller,
            child: KeyedSubtree(
              key: contentKey,
              child: FocusScope(
                node: focusScope,
                parentNode: beside?.focusScope,
                canRequestFocus: focusable,
                descendantsAreFocusable: focusable,
                child: child,
              ),
            ),
            builder: (context, child) =>
                page.buildTransition(context, controller, child!),
          ),
        ),
      ),
    );
  }
}

/// The slot whose transition builds below it.
class _SlotScope extends InheritedWidget {
  const _SlotScope({required this.slot, required super.child});

  final ScreenSlot slot;

  @override
  bool updateShouldNotify(_SlotScope oldWidget) => slot != oldWidget.slot;
}

/// A back gesture driving a slot's transition.
sealed class _BackGesture {
  const _BackGesture();
}

/// The finger, or the predictive back's progress, sets the transition.
final class _Tracking extends _BackGesture {
  const _Tracking();
}

/// The gesture let go at [from], and the transition settles to [to].
final class _Settling extends _BackGesture {
  _Settling(this.from, this.to);

  final double from;
  final double to;
}

/// [ScreenSlot.curved]'s animation.
class _GestureCurve extends Animation<double>
    with AnimationWithParentMixin<double> {
  _GestureCurve(this.parent, this.curve, this.slot);

  @override
  final Animation<double> parent;
  final Curve curve;
  final ScreenSlot slot;

  @override
  double get value {
    final t = parent.value;
    return switch (slot._backGesture) {
      null => curve.transform(t),
      _Tracking() => t,
      _Settling(:final from, :final to) => from == to
          ? t
          : from + (to - from) * curve.transform((t - from) / (to - from)),
    };
  }
}

/// Wraps a screen entry and, while it is the top one, drives its
/// [AnimationController] by the back gestures: the iOS edge swipe by the
/// finger's travel since the touch went down, over the entry's width, and
/// Android's predictive back by the gesture's progress. Once the gesture lets
/// go the entry settles from there, popping when the gesture commits and
/// otherwise returning to 1 over 150 ms.
class ScreenBackHandler extends StatefulWidget {
  /// Binds the slot the gesture drags and the pop it commits to.
  const ScreenBackHandler({
    super.key,
    required this.entry,
    required this.enabled,
    required this.onPop,
  });

  /// The slot whose controller the gesture drives.
  final ScreenSlot entry;

  /// Whether the gesture is accepted at all.
  final bool enabled;

  /// Called when the gesture commits rather than being cancelled.
  final VoidCallback onPop;

  @override
  State<ScreenBackHandler> createState() => ScreenBackHandlerState();
}

/// Predictive-back gesture state of a [ScreenBackHandler].
class ScreenBackHandlerState extends State<ScreenBackHandler>
    with WidgetsBindingObserver {
  bool _gestureInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (!widget.enabled || backEvent.isButtonEvent) return false;
    _gestureInProgress = true;
    widget.entry._backGesture = const _Tracking();
    widget.entry.controller.value = 1.0 - backEvent.progress;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_gestureInProgress) return;
    widget.entry.controller.value = 1.0 - backEvent.progress;
  }

  @override
  void handleCommitBackGesture() {
    if (!_gestureInProgress) return;
    _gestureInProgress = false;
    _pop();
  }

  @override
  void handleCancelBackGesture() {
    if (!_gestureInProgress) return;
    _gestureInProgress = false;
    _springBack();
  }

  void _pop() {
    widget.entry._backGesture = _Settling(widget.entry.controller.value, 0);
    widget.onPop();
  }

  void _springBack() {
    final entry = widget.entry;
    final settling = _Settling(entry.controller.value, 1);
    entry._backGesture = settling;
    entry.controller
        .animateTo(1.0, duration: const Duration(milliseconds: 150))
        .whenCompleteOrCancel(() {
      if (entry._backGesture == settling) entry._backGesture = null;
    });
  }

  // ── iOS edge swipe ──

  late double _swipeStart;

  static const _edgeWidth = 40.0;

  void _onHorizontalDragStart(DragStartDetails d) {
    _swipeStart = d.localPosition.dx;
    widget.entry._backGesture = const _Tracking();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    final travel = d.localPosition.dx - _swipeStart;
    widget.entry.controller.value =
        1.0 - (travel / context.size!.width).clamp(0.0, 1.0);
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (widget.entry.controller.value < 0.5 || d.velocity.pixelsPerSecond.dx > 300) {
      _pop();
    } else {
      _springBack();
    }
  }

  bool get _isIOSLike {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.entry.build(context),
        // Left edge swipe strip — sits on top to catch horizontal drags
        // without competing with the page's scroll views.
        if (_isIOSLike && widget.enabled && widget.entry.page.canSwipeBack)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _edgeWidth,
            child: GestureDetector(
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragStart: _onHorizontalDragStart,
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              onHorizontalDragEnd: _onHorizontalDragEnd,
              behavior: HitTestBehavior.translucent,
            ),
          ),
      ],
    );
  }
}
