import 'package:ux/src/navi/screen.dart';

/// A target for [Screen]-level pushes. Implementations include
/// [XRouter] (the global navigator) and `_SheetNestedHost` (the
/// inner stack of a `SheetScreen`).
///
/// Mirrors UIKit's pattern where every `UIViewController` knows its
/// `navigationController`: pages route via the host they were pushed
/// onto rather than walking ancestor stacks or looking up global
/// state.
abstract class ScreenHost {
  /// Push [page] onto this host's stack. Future completes when
  /// [page] is popped (with the popped result, or `null` on dismiss).
  Future<R?> push<R>(Screen<R> page);
}
