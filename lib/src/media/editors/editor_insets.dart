import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:ux/src/media/design.dart';

/// Safe-area and keyboard insets for the editor screens, taken from the
/// binding rather than from `MediaQuery`: `XRouter` strips the keyboard's
/// bottom inset out of the tree's `viewInsets` and `viewPadding` before a
/// screen sees them.
Listenable get editorInsets => insets;

/// The safe-area inset at the top.
double get editorSafeAreaTop => insets.viewPadding.top;

/// The safe-area inset at the bottom.
double get editorSafeAreaBottom => insets.viewPadding.bottom;

/// Keyboard height net of the safe-area bottom it covers — how far
/// bottom-anchored chrome rides up for its visible edge to sit on the
/// keyboard's top.
double get editorKeyboardLift => math.max(
  0.0,
  insets.keyboardInset - editorSafeAreaBottom,
);
