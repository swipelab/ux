import 'package:flutter/material.dart';

import 'package:ux/src/navi/screen_stack.dart';

/// A shared-element widget that animates between two positions
/// when the [ScreenStack] pushes or pops a screen.
///
/// Place [ScreenHero] widgets with the same [tag] on different screens.
/// When a screen is pushed over another or popped off it, the hero "flies"
/// from its place on one to its place on the other inside an [Overlay], over
/// the transition. A pop that a back gesture drives does not fly, and a
/// flight lands as either screen hides.
class ScreenHero extends StatefulWidget {
  /// Binds the matching [tag] to the [child] that flies under it.
  const ScreenHero({
    super.key,
    required this.tag,
    required this.child,
    this.createRectTween,
  });

  /// Identifier used to match heroes across pages.
  final Object tag;

  /// The widget to display (and animate during flight).
  final Widget child;

  /// Optional custom tween for the Rect interpolation.
  final CreateRectTween? createRectTween;

  @override
  State<ScreenHero> createState() => ScreenHeroState();
}

/// Flight state of a [ScreenHero]: it holds the child's place in the layout
/// while the overlay copy is in the air.
class ScreenHeroState extends State<ScreenHero> {
  ScreenHeroController? _controller;
  Size? _placeholderSize;

  @override
  void initState() {
    super.initState();
    _controller = ScreenStack.maybeOf(context)?.heroController?..register(this);
  }

  @override
  void dispose() {
    _controller?.unregister(this);
    super.dispose();
  }

  /// Hands the child over to the overlay, leaving a gap of its last size.
  void startFlight() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    setState(() => _placeholderSize = box.size);
  }

  /// Takes the child back from the overlay and drops the gap.
  void endFlight() {
    if (!mounted) return;
    setState(() => _placeholderSize = null);
  }

  /// Where this hero lies in [space] once [slot]'s transition settles, which
  /// leaves the screen right on the slot; `null` before the first layout.
  Rect? _restingRect(ScreenSlot slot, RenderBox space) {
    final box = context.findRenderObject()! as RenderBox;
    if (!box.hasSize) return null;
    final screen = slot.contentKey.currentContext!.findRenderObject()!;
    final frame = slot.key.currentContext!.findRenderObject()!;
    return MatrixUtils.transformRect(
      frame.getTransformTo(space)..multiply(box.getTransformTo(screen)),
      Offset.zero & box.size,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_placeholderSize != null) {
      return SizedBox.fromSize(size: _placeholderSize);
    }
    return widget.child;
  }
}

/// Registry + flight controller, owned by [ScreenStackState].
class ScreenHeroController {
  final Set<ScreenHeroState> _heroes = {};

  /// What lands each flight in the air, with the slots it flies between.
  final Map<VoidCallback, Set<ScreenSlot>> _landings = {};

  /// Makes [hero] one that flies between the stack's screens.
  void register(ScreenHeroState hero) => _heroes.add(hero);

  /// Drops [hero] from the ones that fly.
  void unregister(ScreenHeroState hero) => _heroes.remove(hero);

  /// Flies each hero on [from]'s screen to the hero with its tag on [to]'s,
  /// in [overlay], as [progress] runs from 0 to 1. A hero already in the air
  /// stays on its flight.
  void fly({
    required ScreenSlot from,
    required ScreenSlot to,
    required Animation<double> progress,
    required OverlayState overlay,
  }) {
    final space = overlay.context.findRenderObject()! as RenderBox;
    final targets = _heroesOn(to);
    for (final source in _heroesOn(from).values) {
      final target = targets[source.widget.tag];
      if (target == null ||
          source._placeholderSize != null ||
          target._placeholderSize != null) {
        continue;
      }
      final begin = source._restingRect(from, space);
      final end = target._restingRect(to, space);
      if (begin == null || end == null) continue;
      _launch(from, to, source, target, begin, end, progress, overlay);
    }
  }

  /// Lands every flight from or to [slot].
  void land(ScreenSlot slot) {
    for (final MapEntry(key: landing, value: slots)
        in _landings.entries.toList()) {
      if (slots.contains(slot)) landing();
    }
  }

  /// Lands every flight in the air.
  void dispose() {
    for (final landing in _landings.keys.toList()) {
      landing();
    }
  }

  Map<Object, ScreenHeroState> _heroesOn(ScreenSlot slot) => {
    for (final hero in _heroes)
      if (ScreenSlot.maybeOf(hero.context) == slot) hero.widget.tag: hero,
  };

  void _launch(
    ScreenSlot from,
    ScreenSlot to,
    ScreenHeroState source,
    ScreenHeroState target,
    Rect begin,
    Rect end,
    Animation<double> progress,
    OverlayState overlay,
  ) {
    source.startFlight();
    target.startFlight();
    final rect =
        target.widget.createRectTween?.call(begin, end) ??
        RectTween(begin: begin, end: end);
    final entry = OverlayEntry(
      builder: (context) => AnimatedBuilder(
        animation: progress,
        child: IgnorePointer(child: target.widget.child),
        builder: (context, shuttle) => Positioned.fromRect(
          rect: rect.evaluate(progress)!,
          child: shuttle!,
        ),
      ),
    );

    late final AnimationStatusListener onStatus;
    void land() {
      progress.removeStatusListener(onStatus);
      _landings.remove(land);
      entry
        ..remove()
        ..dispose();
      source.endFlight();
      target.endFlight();
    }

    onStatus = (status) {
      if (!status.isAnimating) land();
    };
    progress.addStatusListener(onStatus);
    _landings[land] = {from, to};
    overlay.insert(entry);
  }
}
