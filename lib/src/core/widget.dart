import 'package:flutter/widgets.dart';

/// Geometry of the render object a [GlobalKey] is currently attached to.
extension GlobalKeyExtension on GlobalKey {
  /// Top-left corner in global coordinates, or `null` while unmounted.
  Offset? get position {
    final context = currentContext;
    if (context == null) return null;
    final box = context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset.zero);
    return pos;
  }

  /// Laid-out size, or `null` while unmounted.
  Size? get size {
    final context = currentContext;
    if (context == null) return null;
    final box = context.findRenderObject() as RenderBox;
    return box.size;
  }

  /// Global bounds, with [offset] applied in local space before the
  /// conversion. `null` while unmounted.
  Rect? rect({Offset offset = Offset.zero}) {
    final context = currentContext;
    if (context == null) return null;
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(offset) & box.size;
  }
}

/// Adapts a box widget to a sliver context.
extension SliverExtension on Widget {
  /// Wraps this widget in a [SliverToBoxAdapter].
  Widget sliver({Key? key}) => SliverToBoxAdapter(key: key, child: this);
}
