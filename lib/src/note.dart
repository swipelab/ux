import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:ux/src/util.dart';

const String NOTE_ROUTE = "/ux/note";

typedef void NoteStatusCallback(NoteStatus status);
typedef void OnTap(Note note);

class Note<T extends Object> extends StatefulWidget {
  Note(
      {Key key,
      this.child,
      this.onTap,
      this.duration = const Duration(seconds: 3),
      this.isDismissible = true,
      this.dismissDirection = NoteDismissDirection.Vertical,
      this.position = NotePosition.Bottom,
      this.forwardAnimationCurve = Curves.easeOutCirc,
      this.reverseAnimationCurve = Curves.easeOutCirc,
      this.animationDuration = const Duration(seconds: 1),
      this.onStatusChanged,
      this.isModal = false,
      this.modalBackdropBlur,
      this.modalBackgroundColor})
      : super(key: key);

  final NoteStatusCallback onStatusChanged;

  final Widget child;

  final OnTap onTap;

  final Duration duration;

  final bool isDismissible;

  final NotePosition position;

  final NoteDismissDirection dismissDirection;

  final Curve forwardAnimationCurve;

  /// The [Curve] animation used when dismiss() is called. [Curves.fastOutSlowIn] is default
  final Curve reverseAnimationCurve;

  /// Use it to speed up or slow down the animation duration
  final Duration animationDuration;

  final bool isModal;
  final double modalBackdropBlur;
  final Color modalBackgroundColor;

  NoteRoute<T> _noteRoute;

  Future<T> show(BuildContext context) async {
    _noteRoute = NoteRoute<T>(note: this);
    return await Navigator.of(context, rootNavigator: false).push(_noteRoute);
  }

  Future<T> dismiss([T result]) async {
    // If route was never initialized, do nothing
    if (_noteRoute == null) {
      return null;
    }

    if (_noteRoute.isCurrent) {
      _noteRoute.navigator.pop(result);
      return _noteRoute.completed;
    } else if (_noteRoute.isActive) {
      _noteRoute.navigator.removeRoute(_noteRoute);
    }

    return null;
  }

  bool isShowing() {
    return _noteRoute?.currentStatus == NoteStatus.Visible;
  }

  bool isDismissed() {
    return _noteRoute?.currentStatus == NoteStatus.Dismissed;
  }

  @override
  State createState() {
    return _NoteState<T>();
  }
}

class _NoteState<K extends Object> extends State<Note>
    with TickerProviderStateMixin {
  GlobalKey _backgroundBoxKey;
  NoteStatus currentStatus;
  AnimationController _fadeController;
  FocusScopeNode _focusNode;
  FocusAttachment _focusAttachment;
  Completer<Size> _boxHeightCompleter;

  @override
  void initState() {
    super.initState();

    _backgroundBoxKey = GlobalKey();
    _boxHeightCompleter = Completer<Size>();

    _configureLeftBarFuture();

    _focusNode = FocusScopeNode();
    _focusAttachment = _focusNode.attach(context);
  }

  @override
  void dispose() {
    _fadeController?.dispose();

    _focusAttachment.detach();
    _focusNode.dispose();
    super.dispose();
  }

  void _configureLeftBarFuture() {
    SchedulerBinding.instance.addPostFrameCallback(
      (_) {
        final keyContext = _backgroundBoxKey.currentContext;

        if (keyContext != null) {
          final RenderBox box = keyContext.findRenderObject();
          _boxHeightCompleter.complete(box.size);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        minimum: widget.position == NotePosition.Bottom
            ? EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom)
            : EdgeInsets.only(top: MediaQuery.of(context).viewInsets.top),
        bottom: widget.position == NotePosition.Bottom,
        top: widget.position == NotePosition.Top,
        left: false,
        right: false,
        child: widget.child,
      ),
    );
  }
}

enum NotePosition { Top, Bottom }

enum NoteDismissDirection { Horizontal, Vertical }

enum NoteStatus { Visible, Dismissed, FadeIn, FadeOut }

class NoteRoute<T> extends OverlayRoute<T> {
  final Note note;
  final Builder _builder;
  final Completer<T> _transitionCompleter = Completer<T>();
  final NoteStatusCallback _onStatusChanged;

  Animation<double> _filterBlurAnimation;
  Animation<Color> _filterColorAnimation;
  Alignment _initialAlignment;
  Alignment _endAlignment;
  bool _wasDismissedBySwipe = false;
  Timer _timer;
  T _result;
  NoteStatus currentStatus;

  NoteRoute({
    @required this.note,
    RouteSettings settings = const RouteSettings(name: NOTE_ROUTE),
  })  : _builder = Builder(builder: (BuildContext innerContext) {
          return GestureDetector(
            child: note,
            onTap: note.onTap != null ? () => note.onTap(note) : null,
          );
        }),
        _onStatusChanged = note.onStatusChanged,
        super(settings: settings) {
    _configureAlignment(this.note.position);
  }

  void _configureAlignment(NotePosition position) {
    switch (note.position) {
      case NotePosition.Top:
        {
          _initialAlignment = Alignment(-1.0, -2.0);
          _endAlignment = Alignment(-1.0, -1.0);
          break;
        }
      case NotePosition.Bottom:
        {
          _initialAlignment = Alignment(-1.0, 2.0);
          _endAlignment = Alignment(-1.0, 1.0);
          break;
        }
    }
  }

  Future<T> get completed => _transitionCompleter.future;

  bool get opaque => false;

  @override
  Iterable<OverlayEntry> createOverlayEntries() {
    final List<OverlayEntry> overlays = [];

    if (note.isModal) {
      overlays.add(
        OverlayEntry(
            builder: (BuildContext context) {
              return GestureDetector(
                onTap: note.isDismissible ? () => note.dismiss() : null,
                child: _createBackgroundOverlay(),
              );
            },
            maintainState: false,
            opaque: opaque),
      );
    }

    overlays.add(
      OverlayEntry(
          builder: (BuildContext context) {
            final Widget annotatedChild = Semantics(
              child: AlignTransition(
                alignment: _animation,
                child: note.isDismissible
                    ? _getDismissibleNote(_builder)
                    : _builder,
              ),
              focused: false,
              container: true,
              explicitChildNodes: true,
            );
            return annotatedChild;
          },
          maintainState: false,
          opaque: opaque),
    );

    return overlays;
  }

  Widget _createBackgroundOverlay() {
    if (_filterBlurAnimation != null && _filterColorAnimation != null) {
      return AnimatedBuilder(
        animation: _filterBlurAnimation,
        builder: (context, child) {
          return BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: _filterBlurAnimation.value,
                sigmaY: _filterBlurAnimation.value),
            child: Container(
              constraints: BoxConstraints.expand(),
              color: _filterColorAnimation.value,
            ),
          );
        },
      );
    }

    if (_filterBlurAnimation != null) {
      return AnimatedBuilder(
        animation: _filterBlurAnimation,
        builder: (context, child) {
          return BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: _filterBlurAnimation.value,
                sigmaY: _filterBlurAnimation.value),
            child: Container(
              constraints: BoxConstraints.expand(),
              color: Colors.transparent,
            ),
          );
        },
      );
    }

    if (_filterColorAnimation != null) {
      AnimatedBuilder(
        animation: _filterColorAnimation,
        builder: (context, child) {
          return Container(
            constraints: BoxConstraints.expand(),
            color: _filterColorAnimation.value,
          );
        },
      );
    }

    return Container(
      constraints: BoxConstraints.expand(),
      color: Colors.transparent,
    );
  }

  String dismissKey = nextId().toString();

  Widget _getDismissibleNote(Widget child) {
    return Dismissible(
      direction: _getDismissDirection(),
      resizeDuration: null,
      confirmDismiss: (_) {
        if (currentStatus == NoteStatus.FadeIn ||
            currentStatus == NoteStatus.FadeOut) {
          return Future.value(false);
        }
        return Future.value(true);
      },
      key: Key(dismissKey),
      onDismissed: (_) {
        _cancelTimer();
        _wasDismissedBySwipe = true;

        if (isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(this);
        }
      },
      child: _builder,
    );
  }

  DismissDirection _getDismissDirection() {
    if (note.dismissDirection == NoteDismissDirection.Horizontal) {
      return DismissDirection.horizontal;
    } else {
      if (note.position == NotePosition.Top) {
        return DismissDirection.up;
      } else {
        return DismissDirection.down;
      }
    }
  }

  @override
  bool get finishedWhenPopped =>
      _controller.status == AnimationStatus.dismissed;

  /// The animation that drives the route's transition and the previous route's
  /// forward transition.
  Animation<Alignment> get animation => _animation;
  Animation<Alignment> _animation;

  /// The animation controller that the route uses to drive the transitions.
  ///
  /// The animation itself is exposed by the [animation] property.
  @protected
  AnimationController get controller => _controller;
  AnimationController _controller;

  /// Called to create the animation controller that will drive the transitions to
  /// this route from the previous one, and back to the previous route from this
  /// one.
  AnimationController createAnimationController() {
    assert(!_transitionCompleter.isCompleted,
        'Cannot reuse a $runtimeType after disposing it.');
    assert(note.animationDuration != null &&
        note.animationDuration >= Duration.zero);
    return AnimationController(
      duration: note.animationDuration,
      debugLabel: debugLabel,
      vsync: navigator,
    );
  }

  /// Called to create the animation that exposes the current progress of
  /// the transition controlled by the animation controller created by
  /// [createAnimationController()].
  Animation<Alignment> createAnimation() {
    assert(!_transitionCompleter.isCompleted,
        'Cannot reuse a $runtimeType after disposing it.');
    assert(_controller != null);
    return AlignmentTween(begin: _initialAlignment, end: _endAlignment).animate(
      CurvedAnimation(
        parent: _controller,
        curve: note.forwardAnimationCurve,
        reverseCurve: note.reverseAnimationCurve,
      ),
    );
  }

  Animation<double> createBlurFilterAnimation() {
    if (note.modalBackdropBlur == null) return null;

    return Tween(begin: 0.0, end: note.modalBackdropBlur).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Interval(
          0.0,
          0.35,
          curve: Curves.easeInOutCirc,
        ),
      ),
    );
  }

  Animation<Color> createColorFilterAnimation() {
    if (note.modalBackgroundColor == null) return null;

    return ColorTween(begin: Colors.transparent, end: note.modalBackgroundColor)
        .animate(
      CurvedAnimation(
        parent: _controller,
        curve: Interval(
          0.0,
          0.35,
          curve: Curves.easeInOutCirc,
        ),
      ),
    );
  }

  void _handleStatusChanged(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.completed:
        currentStatus = NoteStatus.Visible;
        _onStatusChanged?.call(currentStatus);
        if (overlayEntries.isNotEmpty) overlayEntries.first.opaque = opaque;

        break;
      case AnimationStatus.forward:
        currentStatus = NoteStatus.FadeIn;
        _onStatusChanged?.call(currentStatus);
        break;
      case AnimationStatus.reverse:
        currentStatus = NoteStatus.FadeOut;
        _onStatusChanged?.call(currentStatus);
        if (overlayEntries.isNotEmpty) overlayEntries.first.opaque = false;
        break;
      case AnimationStatus.dismissed:
        assert(!overlayEntries.first.opaque);

        currentStatus = NoteStatus.Dismissed;
        _onStatusChanged?.call(currentStatus);

        if (!isCurrent) {
          navigator.finalizeRoute(this);
          assert(overlayEntries.isEmpty);
        }
        break;
    }
    changedInternalState();
  }

  @override
  void install(OverlayEntry insertionPoint) {
    assert(!_transitionCompleter.isCompleted,
        'Cannot install a $runtimeType after disposing it.');
    _controller = createAnimationController();
    assert(_controller != null,
        '$runtimeType.createAnimationController() returned null.');
    _filterBlurAnimation = createBlurFilterAnimation();
    _filterColorAnimation = createColorFilterAnimation();
    _animation = createAnimation();
    assert(_animation != null, '$runtimeType.createAnimation() returned null.');
    super.install(insertionPoint);
  }

  @override
  TickerFuture didPush() {
    assert(_controller != null,
        '$runtimeType.didPush called before calling install() or after calling dispose().');
    assert(!_transitionCompleter.isCompleted,
        'Cannot reuse a $runtimeType after disposing it.');
    _animation.addStatusListener(_handleStatusChanged);
    _configureTimer();
    super.didPush();
    return _controller.forward();
  }

  @override
  void didReplace(Route<dynamic> oldRoute) {
    assert(_controller != null,
        '$runtimeType.didReplace called before calling install() or after calling dispose().');
    assert(!_transitionCompleter.isCompleted,
        'Cannot reuse a $runtimeType after disposing it.');
    if (oldRoute is NoteRoute) _controller.value = oldRoute._controller.value;
    _animation.addStatusListener(_handleStatusChanged);
    super.didReplace(oldRoute);
  }

  @override
  bool didPop(T result) {
    assert(_controller != null,
        '$runtimeType.didPop called before calling install() or after calling dispose().');
    assert(!_transitionCompleter.isCompleted,
        'Cannot reuse a $runtimeType after disposing it.');

    _result = result;
    _cancelTimer();

    if (_wasDismissedBySwipe) {
      Timer(Duration(milliseconds: 200), () {
        _controller.reset();
      });

      _wasDismissedBySwipe = false;
    } else {
      _controller.reverse();
    }

    return super.didPop(result);
  }

  void _configureTimer() {
    if (note.duration != null) {
      if (_timer != null && _timer.isActive) {
        _timer.cancel();
      }
      _timer = Timer(note.duration, () {
        if (this.isCurrent) {
          navigator.pop();
        } else if (this.isActive) {
          navigator.removeRoute(this);
        }
      });
    } else {
      if (_timer != null) {
        _timer.cancel();
      }
    }
  }

  void _cancelTimer() {
    if (_timer != null && _timer.isActive) {
      _timer.cancel();
    }
  }

  bool canTransitionTo(NoteRoute<dynamic> nextRoute) => true;

  bool canTransitionFrom(NoteRoute<dynamic> previousRoute) => true;

  @override
  void dispose() {
    assert(!_transitionCompleter.isCompleted,
        'Cannot dispose a $runtimeType twice.');
    _controller?.dispose();
    _transitionCompleter.complete(_result);
    super.dispose();
  }

  String get debugLabel => '$runtimeType';
}
