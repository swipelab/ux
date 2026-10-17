import 'package:flutter/gestures.dart'
    show
        DragStartBehavior,
        HorizontalDragGestureRecognizer,
        PointerPanZoomStartEvent;
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
///   A screen leaving [stack] takes no pointer through its pop animation,
///   and one with none to run, as with a zero [Screen.transitionDuration],
///   leaves in the build that drops it. A leaving screen's
///   [Screen.onRemoved] and [onRemoved] run after the frame it leaves in.
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
class ScreenStackState extends State<ScreenStack>
    with TickerProviderStateMixin {
  late ScreenSlot _homeSlot;
  final List<ScreenSlot> _entries = [];

  /// Entries gone from [_entries] that await their release after the frame.
  final Set<ScreenSlot> _dropped = {};

  /// Matches heroes across the screens in this stack and flies them.
  final ScreenHeroController heroController = ScreenHeroController();
  final FocusScopeNode _outerScope = FocusScopeNode(debugLabel: 'ScreenStack');

  ScreenSlot? _focusedSlot;

  /// The slot of the screen this stack is built in; null at the top level.
  ScreenSlot? _outerSlot;

  /// The outermost stack around this one as this one last built.
  late ScreenStackState _builtRoot;

  /// [canPop] as this stack last told the [NavigationNotification] listeners
  /// around it.
  bool? _toldCanPop;
  bool _reviewingCanPop = false;

  @override
  void initState() {
    super.initState();
    _homeSlot = _createHomeSlot(widget.home);
    for (final page in widget.stack) {
      _entries.add(_createEntry(page, animated: false));
    }
    _sync();
    _scheduleTopFocusHandoff();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final slot = context.dependOnInheritedWidgetOfExactType<_SlotScope>()?.slot;
    if (slot == _outerSlot) return;
    _outerSlot?._stacks.remove(this);
    _outerSlot = slot?.._stacks.add(this);
  }

  void _sync() {
    var under = _homeSlot;
    for (final entry in _entries) {
      if (entry.removing) continue;
      final hidden = widget.hidden.contains(entry.page);
      if (hidden && !entry.hidden) {
        // A shuttle removed while a frame builds stays in the overlay for the
        // next frame, beside the heroes holding their children again.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => heroController.land(entry),
        );
      }
      entry.hidden = hidden;
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
  ///
  /// The top scope takes focus when focus is in this stack, or when focus is
  /// on a scope around it or nowhere and this stack is [_onTop], so keys reach
  /// the top screen; focus elsewhere stays put. [_onTop] reads the stacks, not
  /// focus, because `primaryFocus` lags a request made earlier in the same
  /// frame.
  void _scheduleTopFocusHandoff() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final top = _topSlot;
      if (top == _focusedSlot) return;
      _focusedSlot = top;
      final focus = FocusManager.instance.primaryFocus;
      if (_onTop && (focus == null || _outerScope.ancestors.contains(focus))) {
        top.focusScope.requestFocus();
      } else {
        _outerScope.setFirstFocus(top.focusScope);
      }
    });
  }

  /// Tells the [NavigationNotification] listeners around this stack after the
  /// frame what [canPop] holds, where that changed.
  void _reviewCanPop() {
    if (_reviewingCanPop) return;
    _reviewingCanPop = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reviewingCanPop = false;
      if (!mounted || canPop == _toldCanPop) return;
      _toldCanPop = canPop;
      NavigationNotification(canHandlePop: canPop).dispatch(context);
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
    final oldTop = _topSlot;

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

    _sync();
    final top = _topSlot;
    _flyHeroes(
      oldTop,
      top,
      entered: top != _homeSlot && !oldSet.contains(top.page),
    );
    _scheduleTopFocusHandoff();
    setState(() {});
  }

  /// Flies the heroes from [from], the top screen before a change, to [to],
  /// the one after, over the transition of [to] entering or of [from]
  /// leaving. A pop that a back gesture drives does not fly.
  void _flyHeroes(ScreenSlot from, ScreenSlot to, {required bool entered}) {
    final Animation<double> progress;
    if (entered) {
      progress = to.controller;
    } else if (from.removing && from._backGesture == null) {
      progress = ReverseAnimation(from.controller);
    } else {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !progress.isAnimating) return;
      final overlay = Overlay.maybeOf(context);
      if (overlay == null) return;
      heroController.fly(
        from: from,
        to: to,
        progress: progress,
        overlay: overlay,
      );
    });
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
    if (entry._backGesture case final gesture?) {
      entry._backGesture = _Settling(gesture, entry.controller.value, 0);
    }
    final exit = entry.hidden ? null : entry.controller.reverse();
    if (exit == null || entry.controller.isDismissed) {
      _drop(entry);
    } else {
      exit.then((_) {
        if (mounted) _drop(entry);
      });
    }
  }

  /// Unlists [entry] and releases it after the frame, outside the build that
  /// may drop it, where its removal callbacks can notify any listener.
  void _drop(ScreenSlot entry) {
    _entries.remove(entry);
    _dropped.add(entry);
    if (_focusedSlot == entry) _focusedSlot = null;
    _scheduleTopFocusHandoff();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _dropped.remove(entry);
      entry.controller.dispose();
      entry.focusScope.dispose();
      entry.page.onRemoved();
      widget.onRemoved?.call(entry.page);
    });
    setState(() {});
  }

  @override
  void dispose() {
    _outerSlot?._stacks.remove(this);
    _builtRoot._reviewCanPop();
    heroController.dispose();
    _homeSlot.controller.dispose();
    _homeSlot.focusScope.dispose();
    for (final entry in [..._entries, ..._dropped]) {
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

  /// Whether the screen holding this stack is the top one of every stack
  /// around it.
  bool get _onTop {
    final outer = ScreenStack.maybeOf(context);
    if (outer == null) return true;
    return _outerSlot == outer._topSlot && outer._onTop;
  }

  /// Whether the screen holding this stack [_shows] in the stack around it; a
  /// stack at the top level is shown.
  bool get _shown {
    final outer = ScreenStack.maybeOf(context);
    if (outer == null) return true;
    return outer._shows(_outerSlot);
  }

  /// Whether [slot] holds an unpopped screen that, in this stack and every
  /// stack around it, is the top one or one shown beside it.
  bool _shows(ScreenSlot? slot) =>
      slot != null &&
      !slot.page.popped &&
      _withBeside(_topSlot).contains(slot) &&
      _shown;

  /// [slot] and the screens shown beside it.
  Iterable<ScreenSlot> _withBeside(ScreenSlot slot) => [
    slot,
    ..._entries.where((e) => e.beside == slot && !e.removing && !e.hidden),
  ];

  /// The stacks inside [slot], or inside a screen shown beside it, whose home
  /// is covered.
  Iterable<ScreenStackState> _coversInside(ScreenSlot slot) =>
      _withBeside(slot)
          .where((shown) => !shown.page.popped)
          .expand((shown) => shown._stacks)
          .where((stack) => stack._homeCovered);

  bool _holdsCover(ScreenSlot slot) => _coversInside(slot).isNotEmpty;

  /// The top covering slot whose screen is unpopped, else home.
  ScreenSlot get _backSlot =>
      _entries.lastWhereOrNull((e) => e._covers && !e.page.popped) ?? _homeSlot;

  bool get _homeCovered => _backSlot != _homeSlot || _holdsCover(_homeSlot);

  /// The slot back goes to: [nestedTop]'s where there is one, else
  /// [_backSlot].
  ScreenSlot get _back => _nestedBack ?? _backSlot;

  ScreenSlot? get _nestedBack => _coversInside(_backSlot)
      .map((stack) => stack._back)
      .fold(
        null,
        (last, slot) => last != null && last._order > slot._order ? last : slot,
      );

  /// The top screen of the innermost [ScreenStack] that shows a screen above
  /// its home inside a shown screen, the top one or one beside it, of this
  /// stack and of each stack in between; null where none is. Of several such
  /// stacks, none inside another, as two side by side or one in a screen and
  /// one in the screen shown beside it, it is the screen pushed last of those
  /// each would name, so back undoes the last push still shown. A screen
  /// popped before its stack rebuilds counts as gone.
  Screen? get nestedTop => _nestedBack?.page;

  /// The screen above [ScreenStack.home] that back goes to: [nestedTop] where
  /// there is one, else the top unpopped screen covering the ones under it;
  /// null where back goes to home. Back goes to the outermost stack's: an
  /// `XRouter`'s system back and Esc, and a predictive back to its
  /// [ScreenBackHandler] alone.
  Screen? get backTop {
    final slot = _back;
    return slot == _homeSlot ? null : slot.page;
  }

  /// Whether back has a screen to go to: [backTop] where its [Screen.canPop]
  /// holds, or, where back goes to home, an unpopped screen shown beside
  /// home. After each frame in which it changes, by a change in this stack or
  /// in one inside it, the outermost stack tells the [NavigationNotification]
  /// listeners around it.
  bool get canPop {
    if (backTop case final page?) return page.canPop;
    return _withBeside(_homeSlot).any((e) => e != _homeSlot && !e.page.popped);
  }

  /// The outermost stack around this one, or this one at the top level.
  ScreenStackState get _root => ScreenStack.maybeOf(context)?._root ?? this;

  Widget _place(BuildContext context, ScreenSlot entry, Widget slot) =>
      entry._place?.call(context, entry.page, slot) ?? slot;

  @override
  Widget build(BuildContext context) {
    ScreenBackHandlerState._reviewBacks();
    (_builtRoot = _root)._reviewCanPop();
    final top = _entries.lastWhereOrNull((e) => e._covers);
    final shown = _shown ? _withBeside(_topSlot) : const <ScreenSlot>[];
    for (final slot in [_homeSlot, ..._entries]) {
      slot._shown = shown.contains(slot);
    }
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (intent) {
            final focus = FocusManager.instance.primaryFocus;
            if (focus != null &&
                focus.context != null &&
                focus.context!.findAncestorWidgetOfExactType<EditableText>() !=
                    null) {
              focus.unfocus();
              return null;
            }
            if (top != null && top.page.isModal) {
              top.page.pop();
              return null;
            }
            return Actions.maybeInvoke(context, intent);
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
                  enabled: entry == top && entry.page.canPop,
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
  /// own progress, and once the gesture lets go, or the screen leaves, it runs
  /// [curve] from where the screen shows to where the transition settles.
  static Animation<double> curved(
    BuildContext context,
    Animation<double> animation,
    Curve curve,
  ) {
    final slot = maybeOf(context);
    if (slot == null) return animation.drive(CurveTween(curve: curve));
    return _GestureCurve(animation, curve, slot);
  }

  /// The slot whose screen holds [context], or `null` outside every slot.
  static ScreenSlot? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_SlotScope>()?.slot;

  /// The screen this slot holds; reassigned when an equal screen updates it.
  Screen page;

  /// Drives the enter and exit transitions; 1 when fully on screen.
  final AnimationController controller;

  static int _created = 0;

  /// The slot's place among all slots by creation, the higher the later its
  /// screen was pushed.
  final int _order = _created++;

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

  /// Whether this slot is playing its exit animation, taking no pointer.
  bool removing = false;

  /// The back gesture driving [controller], while one does.
  _BackGesture? _backGesture;

  /// The stacks built inside the screen; while one's home is covered, the
  /// screen takes no back gesture.
  final Set<ScreenStackState> _stacks = {};

  /// Whether the screen is kept offstage: mounted with its State, but
  /// unpainted, out of hit testing and focus, its tickers muted.
  bool hidden = false;

  /// Whether the screen was shown as its stack last built.
  bool _shown = false;

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
        child: IgnorePointer(
          ignoring: removing,
          child: _SlotScope(
            slot: this,
            shown: _shown,
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
      ),
    );
  }
}

/// The slot whose transition builds below it, and whether its screen is
/// shown, so a [ScreenStack] inside the screen rebuilds as that changes.
class _SlotScope extends InheritedWidget {
  const _SlotScope({
    required this.slot,
    required this.shown,
    required super.child,
  });

  final ScreenSlot slot;
  final bool shown;

  @override
  bool updateShouldNotify(_SlotScope oldWidget) =>
      slot != oldWidget.slot || shown != oldWidget.shown;
}

/// A back gesture driving a slot's transition.
sealed class _BackGesture {
  const _BackGesture();

  /// The transition's value on [curve] with the slot's controller at [t].
  double at(double t, Curve curve);
}

/// The finger, or the predictive back's progress, sets the transition.
final class _Tracking extends _BackGesture {
  const _Tracking();

  @override
  double at(double t, Curve curve) => t;
}

/// The transition settles to [to] on its curve, from where [from] shows it
/// with the controller at [start].
final class _Settling extends _BackGesture {
  _Settling(this.from, this.start, this.to);

  final _BackGesture from;
  final double start;
  final double to;

  @override
  double at(double t, Curve curve) {
    if (start == to) return t;
    final shown = from.at(start, curve);
    return shown + (to - shown) * curve.transform((t - start) / (to - start));
  }
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
  double get value =>
      slot._backGesture?.at(parent.value, curve) ??
      curve.transform(parent.value);
}

/// Wraps a screen entry and, while it is the top one, drives its
/// [AnimationController] by each back gesture that starts where its screen's
/// [Screen.canSwipeBack] holds: the iOS edge swipe by the finger's travel
/// since the touch went down, over the entry's width, and Android's predictive
/// back by the gesture's progress.
///
/// One predictive back goes to one handler: that of the outermost
/// [ScreenStack]'s [ScreenStackState.backTop], which an `XRouter`'s system
/// back and Esc go to too. The handler that took it cancels it once a stack's
/// build or the commit names another, as when a [ScreenStack] inside its
/// screen starts showing a screen above its home, or its screen is covered,
/// hidden, popped or leaves.
///
/// The edge swipe starts on the screen whose edge the finger touches, an
/// unpopped one that is the top one in its [ScreenStack] and, in every
/// [ScreenStack] around it, the top one or one shown beside it, and takes none
/// while a [ScreenStack] inside its screen, or inside a screen shown beside
/// it, shows a screen above its home. The gesture arena gives a touch to one
/// edge, so one swipe drags one screen.
///
/// Once a gesture lets go the entry settles from there, popping when the
/// gesture commits and otherwise returning to 1 over 150 ms; a predictive
/// back's commit asks [Screen.handleBack] first, and one it consumes returns
/// the entry to 1 as well. A gesture is cancelled if the handler is disabled
/// before it lets go, and an edge swipe also if its screen stops being shown or
/// turns [Screen.canSwipeBack] false: the entry returns to 1 unless it is
/// leaving.
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
  /// The handlers holding a predictive back.
  static final _backs = <ScreenBackHandlerState>{};

  /// Cancels each predictive back whose handler no longer owns it.
  static void _reviewBacks() {
    for (final handler in [..._backs]) {
      handler._reviewBack();
    }
  }

  /// The outermost [ScreenStack] around the handler while it holds a
  /// predictive back.
  ScreenStackState? _backRoot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cancelRevoked();
  }

  @override
  void didUpdateWidget(ScreenBackHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cancelRevoked();
  }

  @override
  void dispose() {
    _backs.remove(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Whether a predictive back goes to this handler, from [root].
  bool _ownsBack(ScreenStackState root) =>
      widget.enabled && root._back == widget.entry;

  void _reviewBack() {
    if (_backRoot case final root? when !_ownsBack(root)) {
      _releaseBack();
      _cancel();
    }
  }

  void _releaseBack() {
    _backRoot = null;
    _backs.remove(this);
  }

  /// Cancels a predictive back once the handler no longer owns it, and an edge
  /// swipe once the handler no longer takes it. The edge swipe's strip leaves
  /// the tree once the theme leaves iOS or the handler is disabled, so its
  /// drag reports no end.
  void _cancelRevoked() {
    _reviewBack();
    if (_swiping && !_canSwipe) {
      _swiping = false;
      _cancel();
    }
  }

  void _cancel() {
    if (!widget.entry.removing) _springBack();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent || !widget.entry.page.canSwipeBack) {
      return false;
    }
    final root = ScreenStack.of(context)._root;
    if (!_ownsBack(root)) return false;
    _backRoot = root;
    _backs.add(this);
    widget.entry._backGesture = const _Tracking();
    widget.entry.controller.value = 1.0 - backEvent.progress;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_backRoot == null) return;
    widget.entry.controller.value = 1.0 - backEvent.progress;
  }

  @override
  void handleCommitBackGesture() {
    _reviewBack();
    if (_backRoot == null) return;
    _releaseBack();
    if (widget.entry.page.handleBack()) {
      _springBack();
    } else {
      _pop();
    }
  }

  @override
  void handleCancelBackGesture() {
    if (_backRoot == null) return;
    _releaseBack();
    _springBack();
  }

  void _pop() {
    widget.entry._backGesture = _Settling(
      const _Tracking(),
      widget.entry.controller.value,
      0,
    );
    widget.onPop();
  }

  void _springBack() {
    final entry = widget.entry;
    final settling = _Settling(const _Tracking(), entry.controller.value, 1);
    entry._backGesture = settling;
    entry.controller
        .animateTo(1.0, duration: const Duration(milliseconds: 150))
        .whenCompleteOrCancel(() {
          if (entry._backGesture == settling) entry._backGesture = null;
        });
  }

  // ── iOS edge swipe ──

  bool _swiping = false;
  late double _swipeStart;

  static const _edgeWidth = 40.0;

  void _onHorizontalDragStart(DragStartDetails d) {
    _swiping = true;
    _swipeStart = d.localPosition.dx;
    widget.entry._backGesture = const _Tracking();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    _cancelRevoked();
    if (!_swiping) return;
    final travel = d.localPosition.dx - _swipeStart;
    widget.entry.controller.value =
        1.0 - (travel / context.size!.width).clamp(0.0, 1.0);
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    _cancelRevoked();
    if (!_swiping) return;
    _swiping = false;
    if (widget.entry.controller.value < 0.5 ||
        d.velocity.pixelsPerSecond.dx > 300) {
      _pop();
    } else {
      _springBack();
    }
  }

  bool get _isIOSLike {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  }

  bool get _takesSwipe {
    final stack = ScreenStack.of(context);
    return widget.enabled &&
        widget.entry.page.canSwipeBack &&
        stack._shows(widget.entry) &&
        !stack._holdsCover(widget.entry);
  }

  bool get _canSwipe => _isIOSLike && _takesSwipe;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.entry.build(context),
        // Left edge swipe strip — sits on top to catch horizontal drags
        // without competing with the page's scroll views.
        if (_isIOSLike && widget.enabled)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _edgeWidth,
            child: RawGestureDetector(
              behavior: HitTestBehavior.translucent,
              excludeFromSemantics: true,
              gestures: {
                _EdgeSwipeRecognizer:
                    GestureRecognizerFactoryWithHandlers<_EdgeSwipeRecognizer>(
                      () => _EdgeSwipeRecognizer(this),
                      (recognizer) => recognizer
                        ..dragStartBehavior = DragStartBehavior.down
                        ..multitouchDragStrategy = ScrollConfiguration.of(
                          context,
                        ).getMultitouchDragStrategy(context)
                        ..gestureSettings = MediaQuery.maybeGestureSettingsOf(
                          context,
                        )
                        ..onStart = _onHorizontalDragStart
                        ..onUpdate = _onHorizontalDragUpdate
                        ..onEnd = _onHorizontalDragEnd,
                    ),
              },
            ),
          ),
      ],
    );
  }
}

/// The edge swipe's drag. It takes a pointer or trackpad pan only where its
/// handler takes the back gesture as it starts, and leaves any other to the
/// page.
class _EdgeSwipeRecognizer extends HorizontalDragGestureRecognizer {
  _EdgeSwipeRecognizer(this.handler) : super(debugOwner: handler);

  final ScreenBackHandlerState handler;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      handler._takesSwipe && super.isPointerAllowed(event);

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) =>
      handler._takesSwipe && super.isPointerPanZoomAllowed(event);
}
