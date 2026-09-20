import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A live preview between fading background and controls, from cell to slot.
class CameraFlight extends StatelessWidget {
  /// The source rect uses screen coordinates; [target] belongs to [chrome].
  const CameraFlight({
    super.key,
    required this.source,
    required this.target,
    required this.progress,
    required this.preview,
    required this.background,
    required this.chrome,
  });

  /// The cell's bounds in screen coordinates.
  final Rect source;

  /// The page's preview slot, measured after chrome layout.
  final GlobalKey target;

  /// Zero is the cell; one is the page preview.
  final double progress;

  /// The single live preview, including its interpolated corners and icon.
  final Widget preview;

  /// Full-page fill, including the desktop scrim and card.
  final Widget background;

  /// Camera controls with a transparent preview slot and background.
  final Widget chrome;

  @override
  Widget build(BuildContext context) => _FlightLayout(
    source: source,
    target: target,
    progress: progress,
    children: [
      Opacity(opacity: progress, child: background),
      preview,
      Opacity(opacity: progress, child: chrome),
    ],
  );
}

class _FlightLayout extends MultiChildRenderObjectWidget {
  const _FlightLayout({
    required this.source,
    required this.target,
    required this.progress,
    required super.children,
  });
  final Rect source;
  final GlobalKey target;
  final double progress;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFlight(source, target, progress);

  @override
  void updateRenderObject(BuildContext context, _RenderFlight renderObject) {
    renderObject
      ..source = source
      ..target = target
      ..progress = progress
      ..markNeedsLayout();
  }
}

class _FlightParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFlight extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  _RenderFlight(this.source, this.target, this.progress);
  Rect source;
  GlobalKey target;
  double progress;
  late Rect _destination;
  RenderBox get _preview => childAfter(firstChild!)!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FlightParentData) {
      child.parentData = _FlightParentData();
    }
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    firstChild!.layout(BoxConstraints.tight(size));
    lastChild!.layout(BoxConstraints.tight(size));
    final slot = target.currentContext!.findRenderObject() as RenderBox;
    // The tight preview slot exposes its bounds during ancestor layout.
    _destination = MatrixUtils.transformRect(
      slot.getTransformTo(this),
      Offset.zero & slot.constraints.biggest,
    );
    _preview.layout(
      BoxConstraints.tight(
        Size.lerp(source.size, _destination.size, progress)!,
      ),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Ancestor paint transforms are final only after layout.
    final origin = source.shift(-localToGlobal(Offset.zero));
    final rect = Rect.lerp(origin, _destination, progress)!;
    (_preview.parentData as ContainerBoxParentData<RenderBox>).offset =
        rect.topLeft;
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
