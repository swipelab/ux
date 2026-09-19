import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Vertical breathing room subtracted from the editor surface so the
/// image never butts up against the top bar / caption strip. Telegram
/// uses the same gutter on its media-editor surface.
const double kEditorSurfacePadding = 16;

/// Reports its child's layout size to [onSize] after each layout pass.
/// Used by compose / tool screens to measure floating chrome (top bar,
/// bottom strip, controls) so the editor's `fitRect` can subtract them
/// from the full-bleed editor area.
class OnSize extends SingleChildRenderObjectWidget {
  /// Creates the reporter.
  const OnSize({super.key, required Widget super.child, required this.onSize});

  /// Receives the child's size when it changes.
  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _OnSizeRenderBox(onSize);

  @override
  // ignore: library_private_types_in_public_api
  void updateRenderObject(BuildContext context, _OnSizeRenderBox renderObject) {
    renderObject.onSize = onSize;
  }
}

class _OnSizeRenderBox extends RenderProxyBox {
  _OnSizeRenderBox(this.onSize);

  ValueChanged<Size> onSize;
  Size _last = Size.zero;

  @override
  void performLayout() {
    super.performLayout();
    if (size != _last) {
      _last = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onSize(size));
    }
  }
}
