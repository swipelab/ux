import 'package:flutter/widgets.dart';

/// Carries the screen-stack's transition animation down through the tool
/// screen subtree so the chrome can animate independently of the preview.
/// The preview reads nothing from this and stays visually static across
/// the push / pop boundary — same model as telegram-iOS, where the
/// `previewContainerView` doesn't move during `animateOutToTool` /
/// `animateInFromTool` (only the host's button row does).
class ToolTransition extends InheritedWidget {
  /// Creates the carrier of [animation].
  const ToolTransition({
    super.key,
    required this.animation,
    required super.child,
  });

  /// The tool screen's route animation.
  final Animation<double> animation;

  /// The nearest [ToolTransition]'s animation; stopped at 1 when there is none.
  static Animation<double> of(BuildContext context) {
    final widget = context
        .dependOnInheritedWidgetOfExactType<ToolTransition>();
    return widget?.animation ?? const AlwaysStoppedAnimation<double>(1.0);
  }

  @override
  bool updateShouldNotify(ToolTransition old) => animation != old.animation;
}

/// Animates the tool's controls strip in / out: scales `0.1 → 1.0` and
/// slides `+30 logical px → 0` over the screen's transition. Mirrors
/// telegram's `animateOutToTool` chrome scale (`MediaEditorScreen.swift:677-704`)
/// run in reverse for the tool entering. The preview / canvas isn't
/// wrapped — it stays put.
class AnimatedToolChrome extends StatelessWidget {
  /// Creates the animated wrapper of [child].
  const AnimatedToolChrome({super.key, required this.child});

  /// The controls strip.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animation = ToolTransition.of(context);
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeInOut,
      reverseCurve: Curves.easeInOut,
    );
    return AnimatedBuilder(
      animation: curved,
      child: child,
      builder: (context, child) {
        final t = curved.value;
        final scale = 0.1 + 0.9 * t;
        final slide = 30 * (1 - t);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, slide),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
