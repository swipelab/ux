import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:ux/src/media/camera/camera_session.dart';
import 'package:ux/src/media/camera/camera_thumb.dart';
import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/touch.dart';

/// The mounted cell's bounds and its exclusive loan of the preview to a page.
class CameraCellSource {
  final _key = GlobalKey();
  bool _covered = false;

  /// Screen coordinates, absent when the cell is outside the mounted grid.
  Rect? get rect {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
  }

  /// Only the borrowing page paints the preview until it is removed.
  void cover() {
    _setCovered(true);
  }

  void _setCovered(bool covered) {
    if (_covered == covered) return;
    _covered = covered;
    final box = _key.currentContext?.findRenderObject();
    box?.markNeedsPaint();
    box?.markNeedsSemanticsUpdate();
  }

  /// Returns painting to the cell after the page's exit animation.
  void uncover() {
    _setCovered(false);
  }
}

/// The picker's rounded live preview and camera affordance.
class CameraCell extends StatelessWidget {
  /// Binds the source to its session and tap action.
  const CameraCell({
    super.key,
    required this.source,
    required this.session,
    required this.onTap,
  });

  /// Bounds and painting ownership shared with the camera page.
  final CameraCellSource source;

  /// The picker's camera allocation.
  final CameraSession session;

  /// Opens the camera page.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _CellVisibility(
    key: source._key,
    source: source,
    child: Touch(
      onPress: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CameraThumb(controller: session, child: const CameraCellIcon()),
      ),
    ),
  );
}

class _CellVisibility extends SingleChildRenderObjectWidget {
  const _CellVisibility({
    super.key,
    required this.source,
    required super.child,
  });
  final CameraCellSource source;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCellVisibility(source);

  @override
  SingleChildRenderObjectElement createElement() => _CellElement(this);
}

class _CellElement extends SingleChildRenderObjectElement {
  _CellElement(_CellVisibility super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    if (!(widget as _CellVisibility).source._covered) {
      super.debugVisitOnstageChildren(visitor);
    }
  }
}

class _RenderCellVisibility extends RenderProxyBox {
  _RenderCellVisibility(this.source);
  final CameraCellSource source;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!source._covered) super.paint(context, offset);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !source._covered && super.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (!source._covered) super.visitChildrenForSemantics(visitor);
  }
}

/// The cell affordance, fading away as its preview expands.
class CameraCellIcon extends StatelessWidget {
  /// Creates the camera affordance.
  const CameraCellIcon({super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topRight,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Icon(CupertinoIcons.camera, color: colors.onMedia),
    ),
  );
}
