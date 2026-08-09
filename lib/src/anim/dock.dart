import 'package:flutter/widgets.dart';

/// Named [Positioned] presets for the common [Stack] edges and corners. Each
/// preset pins the edges its name implies and leaves the rest free.
abstract class Dock {
  /// Pinned to the top edge, spanning its width.
  static Widget top({
    required Widget child,
    double? left = 0,
    double? right = 0,
    double? top = 0,
    double? bottom,
    double? height,
    double? width,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      width: width,
      height: height,
      child: child,
    );
  }

  /// Pinned to the bottom edge, spanning its width.
  static Widget bottom({
    required Widget child,
    double? left = 0,
    double? right = 0,
    double? top,
    double? bottom = 0,
    double? width,
    double? height,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: child,
    );
  }

  /// Pinned to the bottom-right corner, sized to its child.
  static Widget bottomRight({
    required Widget child,
    double? left,
    double? right = 0,
    double? top,
    double? bottom = 0,
    double? width,
    double? height,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: child,
    );
  }

  /// Pinned to the top-right corner, sized to its child.
  static Widget topRight({
    required Widget child,
    double? left,
    double? right = 0,
    double? top = 0,
    double? bottom,
    double? width,
    double? height,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: child,
    );
  }

  /// Pinned to the top-left corner, sized to its child.
  static Widget topLeft({
    required Widget child,
    double? left = 0,
    double? right,
    double? top = 0,
    double? bottom,
    double? width,
    double? height,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: child,
    );
  }

  /// Stretched across the stack, inset by whichever edges are given.
  static Widget fill({
    required Widget child,
    double? left,
    double? right,
    double? top,
    double? bottom,
  }) {
    return Positioned.fill(
      left: left,
      right: right,
      bottom: bottom,
      top: top,
      child: child,
    );
  }
}
