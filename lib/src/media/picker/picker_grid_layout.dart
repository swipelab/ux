import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// Square assets with an optional first child spanning two rows.
class PickerGridDelegate extends SliverGridDelegate {
  /// Reserves column zero of the first two rows when [hasCamera] is true.
  const PickerGridDelegate({required this.columns, required this.hasCamera});

  /// Number of square columns.
  final int columns;

  /// Whether child zero is the camera.
  final bool hasCamera;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) =>
      _PickerGridLayout(
        columns: columns,
        hasCamera: hasCamera,
        width: constraints.crossAxisExtent,
        reversed: axisDirectionIsReversed(constraints.crossAxisDirection),
      );

  @override
  bool shouldRelayout(PickerGridDelegate oldDelegate) =>
      columns != oldDelegate.columns || hasCamera != oldDelegate.hasCamera;
}

class _PickerGridLayout extends SliverGridLayout {
  const _PickerGridLayout({
    required this.columns,
    required this.hasCamera,
    required this.width,
    required this.reversed,
  });

  final int columns;
  final bool hasCamera;
  final double width;
  final bool reversed;
  static const gap = 2.0;
  double get side => math.max(0, (width - (columns - 1) * gap) / columns);
  double get stride => side + gap;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    final row = scrollOffset ~/ stride;
    // Child zero still paints in the second row.
    if (hasCamera && row < 2) return 0;
    return row * columns - (hasCamera ? 1 : 0);
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    final rows = (scrollOffset / stride).ceil();
    return math.max(0, rows * columns - 1 - (hasCamera && rows > 1 ? 1 : 0));
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    final slot = index + (hasCamera && index >= columns ? 1 : 0);
    final crossOffset = (slot % columns) * stride;
    return SliverGridGeometry(
      scrollOffset: (slot ~/ columns) * stride,
      crossAxisOffset: reversed ? width - side - crossOffset : crossOffset,
      mainAxisExtent: hasCamera && index == 0 ? side * 2 + gap : side,
      crossAxisExtent: side,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) {
    if (childCount == 0) return 0;
    final slots = childCount + (hasCamera ? 1 : 0);
    final rows = math.max(hasCamera ? 2 : 1, (slots / columns).ceil());
    return rows * stride - gap;
  }
}
