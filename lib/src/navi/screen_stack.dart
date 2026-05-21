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
  const ScreenStack({
    super.key,
    required this.home,
    this.stack = const [],
    this.onRemoved,
  });

  final Screen home;
  final List<Screen> stack;
  final ValueChanged<Screen>? onRemoved;

  @override
  State<ScreenStack> createState() => ScreenStackState();

  static ScreenStackState of(BuildContext context) {
    return context.findAncestorStateOfType<ScreenStackState>()!;
  }

  static ScreenStackState? maybeOf(BuildContext context) {
    return context.findAncestorStateOfType<ScreenStackState>();
  }
}

class ScreenStackState extends State<ScreenStack> with TickerProviderStateMixin {
  late ScreenSlot _homeSlot;
  final List<ScreenSlot> _entries = [];
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
    _updateCanPop();
    _scheduleTopFocusHandoff();
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
    final canPop = _entries.any((e) => !e.removing);
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
    entry.controller.reverse().then((_) {
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

  /// Topmost live slot — the last non-removing pushed entry if any,
  /// else home. Used for focus handoff.
  ScreenSlot get _topSlot =>
      _entries.lastWhereOrNull((e) => !e.removing) ?? _homeSlot;

  @override
  Widget build(BuildContext context) {
    final top = _entries.lastWhereOrNull((e) => !e.removing);
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
              ScreenBackHandler(
                key: entry.key,
                entry: entry,
                enabled: entry == top && _canPop,
                onPop: () => entry.page.pop(),
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
  ScreenSlot({required this.page, required this.controller});

  Screen page;
  final AnimationController controller;
  final key = GlobalKey();
  final contentKey = GlobalKey();
  // Each slot owns its own FocusScope so pushed pages start with a clean
  // focus state — the outer ScreenStack scope calls `setFirstFocus` on this
  // node when the slot becomes top, matching Navigator's per-route scope
  // handoff. Without per-slot scopes, a new page's `autofocus: true`
  // TextField silently no-ops (the outgoing page's focus still occupies the
  // shared scope's `_focusedChildren`), and without `setFirstFocus` the
  // keyboard token is never consumed so no keyboard appears.
  final focusScope = FocusScopeNode();
  bool removing = false;

  Widget build(BuildContext context) {
    final child = page is Listenable
        ? ListenableBuilder(
            listenable: page as Listenable,
            builder: (context, _) => page.buildPresenter(context),
          )
        : page.buildPresenter(context);

    return AnimatedBuilder(
      animation: controller,
      child: FocusScope(node: focusScope, child: child),
      builder: (context, child) =>
          page.buildTransition(context, controller, child!),
    );
  }
}

/// Wraps the top screen entry and handles Android predictive back gestures.
/// Drives the entry's [AnimationController] in response to gesture progress.
class ScreenBackHandler extends StatefulWidget {
  const ScreenBackHandler({
    super.key,
    required this.entry,
    required this.enabled,
    required this.onPop,
  });

  final ScreenSlot entry;
  final bool enabled;
  final VoidCallback onPop;

  @override
  State<ScreenBackHandler> createState() => ScreenBackHandlerState();
}

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
    widget.onPop();
  }

  @override
  void handleCancelBackGesture() {
    if (!_gestureInProgress) return;
    _gestureInProgress = false;
    widget.entry.controller.animateTo(1.0,
        duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
  }

  // ── iOS edge swipe ──

  bool _swiping = false;
  double _swipeStart = 0;

  static const _edgeWidth = 40.0;

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (!widget.enabled) return;
    if (!_swiping) {
      _swiping = true;
      _swipeStart = 0;
    }
    final width = context.size?.width ?? 400;
    final progress = ((d.localPosition.dx - _swipeStart) / width).clamp(0.0, 1.0);
    widget.entry.controller.value = 1.0 - progress;
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (!_swiping) return;
    _swiping = false;
    if (widget.entry.controller.value < 0.5 || d.velocity.pixelsPerSecond.dx > 300) {
      widget.onPop();
    } else {
      widget.entry.controller.animateTo(1.0,
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
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
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              onHorizontalDragEnd: _onHorizontalDragEnd,
              behavior: HitTestBehavior.translucent,
            ),
          ),
      ],
    );
  }
}
