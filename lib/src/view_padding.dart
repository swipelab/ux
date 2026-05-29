import 'dart:ui' show FlutterView;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Smoothly-animated view padding (safe-area insets).
///
/// Replaces a raw `view.viewPadding` read with a value that lerps toward the
/// system inset over [duration] when it changes — so when the OS bars toggle
/// visibility (e.g. switching out of `SystemUiMode.immersiveSticky` back to
/// `edgeToEdge`) bottom- and top-anchored UI slides into place instead of
/// snapping by the nav-bar / status-bar height.
///
/// Use the singleton [instance] and listen via [addListener]; or wrap a
/// subtree in [XAnimatedInsets] so descendant `MediaQuery.viewPaddingOf`
/// reads pick up the animated value.
///
/// Tracks only `viewPadding` — keyboard insets (`viewInsets`) are handled by
/// [XKeyboard] and intentionally bypass this smoothing.
class XInsets with ChangeNotifier, WidgetsBindingObserver {
  XInsets._() {
    WidgetsBinding.instance.addObserver(this);
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    _system = _read(view);
    _current = _system;
  }

  /// Singleton instance. Constructed lazily on first access; requires
  /// `WidgetsFlutterBinding.ensureInitialized()` to have been called.
  static final XInsets instance = XInsets._();

  EdgeInsets _system = EdgeInsets.zero;
  EdgeInsets _current = EdgeInsets.zero;
  EdgeInsets _from = EdgeInsets.zero;
  // Lazy: captured on the first _tick of an animation so the value lives in
  // the same time domain as the frame-callback `ts` parameter (epoch-adjusted),
  // not the raw `currentSystemFrameTimeStamp` which is since-boot.
  Duration? _start;
  bool _ticking = false;
  Duration? _nextAnimationDuration;

  /// Lerp curve.
  Curve curve = Curves.easeOut;

  /// Wraps [SystemChrome.setEnabledSystemUIMode]. The resulting metric
  /// change (Android relaying out the activity for / against immersive)
  /// animates `viewPadding` from the current value to the new system value
  /// over [animate]. Pass `null` (or omit) to snap. Use this rather than
  /// calling `SystemChrome.setEnabledSystemUIMode` directly when entering
  /// or exiting immersive — otherwise the underlying chrome (NavBar /
  /// BottomBar / composer) snaps into place by ~status-bar height.
  Future<void> setSystemUiMode(
    SystemUiMode mode, {
    Duration? animate,
  }) async {
    _nextAnimationDuration = animate;
    await SystemChrome.setEnabledSystemUIMode(mode);
  }

  /// Smoothed view-padding in logical pixels.
  EdgeInsets get viewPadding => _current;

  /// Raw system view-padding (the un-lerped target). Use sparingly — most
  /// callers want [viewPadding].
  EdgeInsets get systemViewPadding => _system;

  @override
  void didChangeMetrics() {
    final next = _read(WidgetsBinding.instance.platformDispatcher.implicitView);
    if (next == _system) return;
    _system = next;
    final animDuration = _nextAnimationDuration;
    _nextAnimationDuration = null;
    if (animDuration == null || animDuration == Duration.zero) {
      _current = next;
      _ticking = false;
      notifyListeners();
      return;
    }
    _from = _current;
    _animDuration = animDuration;
    _start = null;
    _ticking = true;
    SchedulerBinding.instance.scheduleFrameCallback(_tick);
    SchedulerBinding.instance.scheduleFrame();
  }

  Duration _animDuration = Duration.zero;

  void _tick(Duration ts) {
    if (!_ticking) return;
    _start ??= ts;
    final dt = (ts - _start!).inMicroseconds / _animDuration.inMicroseconds;
    final t = curve.transform(dt.clamp(0.0, 1.0));
    _current = EdgeInsets.lerp(_from, _system, t)!;
    notifyListeners();
    if (dt < 1.0) {
      SchedulerBinding.instance.scheduleFrameCallback(_tick);
      SchedulerBinding.instance.scheduleFrame();
    } else {
      _ticking = false;
      _start = null;
    }
  }

  static EdgeInsets _read(FlutterView? v) {
    if (v == null) return EdgeInsets.zero;
    final r = v.devicePixelRatio;
    final p = v.viewPadding;
    return EdgeInsets.fromLTRB(p.left / r, p.top / r, p.right / r, p.bottom / r);
  }
}

/// Wraps [child] in a [MediaQuery] whose `viewPadding` is sourced from
/// [XInsets.instance] (smoothly animated). Use once at the app root so every
/// descendant `MediaQuery.viewPaddingOf(context)` read returns the animated
/// value.
class XAnimatedInsets extends StatefulWidget {
  const XAnimatedInsets({super.key, required this.child});

  final Widget child;

  @override
  State<XAnimatedInsets> createState() => _XAnimatedInsetsState();
}

class _XAnimatedInsetsState extends State<XAnimatedInsets> {
  @override
  void initState() {
    super.initState();
    XInsets.instance.addListener(_onTick);
  }

  @override
  void dispose() {
    XInsets.instance.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(viewPadding: XInsets.instance.viewPadding),
      child: widget.child,
    );
  }
}
