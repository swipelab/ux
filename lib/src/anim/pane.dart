import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:ux/src/core/core.dart';

/// Layout and paint for a viewport whose children are built on demand,
/// keyed by an arbitrary slot.
///
/// A subclass owns the geometry: it implements [performLayout] and [paint],
/// builds each slot through [itemBuilder], and pulls slots into existence
/// with [invokeLayoutUpsert]. [PaneView] mounts it into a [Scrollable].
abstract class Pane with Emitter {
  /// Creates a pane that is not yet attached to an element or renderer.
  Pane();

  /// Widget most recently built for each live slot.
  final Map<Object?, Widget> widgets = {};

  /// Element inflated for each live slot.
  final Map<Object?, Element> elements = {};

  /// Render box of each live slot, in slot order-independent form.
  final Map<Object?, RenderBox> renderBoxes = {};

  /// The mounted element, or `null` while this pane manages no children.
  PaneElement? element;

  /// The mounted render box, or `null` while this pane manages no children.
  PaneRender? renderer;

  /// Whether the mounted renderer needs its own compositing layer.
  bool get needsCompositing => renderer?.needsCompositing ?? false;

  /// The renderer's size. Only valid from [performLayout] onward.
  Size get size => renderer!.size;

  /// Constraints the parent handed the renderer. Only valid from
  /// [performLayout] onward.
  BoxConstraints get constraints => renderer!.constraints;

  /// Schedules a layout pass for the mounted renderer.
  void markNeedsLayout() => renderer?.markNeedsLayout();

  /// Schedules a paint pass for the mounted renderer.
  void markNeedsPaint() => renderer?.markNeedsPaint();

  /// Attaches every child that is not already owned to [owner].
  void attachPipeline(PipelineOwner owner) {
    for (final child in renderBoxes.values) {
      if (child.owner == null) {
        child.attach(owner);
      }
    }
  }

  /// Detaches every child from the pipeline.
  void detachPipeline() {
    for (final child in renderBoxes.values) {
      child.detach();
    }
  }

  /// Walks the child render boxes.
  void visitChildrenRender(RenderObjectVisitor visitor) =>
      renderBoxes.values.forEach(visitor);

  /// Installs the parent data a subclass's layout reads back, on a [child]
  /// just adopted into [slot].
  void setupParentData(covariant RenderObject child, covariant Object? slot);

  /// Children as the widget inspector should show them.
  List<DiagnosticsNode> debugDescribeChildren() => const [];

  /// Adds this pane's state to the renderer's diagnostics.
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {}

  /// Applies the paint-time offset of [child] to [transform].
  void applyPaintTransform(covariant RenderObject child, Matrix4 transform) {}

  /// Hit-tests the children at [position], in this pane's coordinates.
  bool hitTestChildren(BoxHitTestResult result, Offset position) => false;

  /// Whether this pane itself absorbs a hit at [position].
  bool hitTestSelf(Offset position) => false;

  /// [constraints] are available
  /// [size] must be set
  void performLayout();

  /// Paints the laid-out children at [offset].
  void paint(PaintingContext context, Offset offset);

  /// Adopts [child] as the render box of [slot].
  void insertRenderObjectChild(
      PaneElement paneElement, covariant RenderBox child, Object? slot) {
    setupParentData(child, slot);
    renderBoxes[slot] = child;
    renderer?.adoptChild(child);
  }

  /// Re-slots [child] from [oldSlot] to [newSlot].
  void moveRenderObjectChild(PaneElement paneElement, RenderObject child,
      Object? oldSlot, Object? newSlot) {}

  /// Drops the render box held for [slot].
  void removeRenderObjectChild(
      PaneElement paneElement, RenderObject child, Object? slot) {
    renderBoxes.remove(slot);
    renderer?.dropChild(child);
  }

  /// Walks the child elements.
  void visitChildrenElement(ElementVisitor visitor) =>
      elements.values.forEach(visitor);

  /// Builds the widget that fills [slot].
  Widget itemBuilder(BuildContext context, Object? slot);

  /// The render box of [slot], building it inside a layout callback when it
  /// does not exist yet. `null` while this pane is unmounted.
  RenderBox? invokeLayoutUpsert(Object? slot) {
    if (element == null) return null;
    RenderBox? child = renderBoxes[slot];
    if (child != null) return child;
    renderer?.invokeLayoutCallback((constraints) {
      child = buildChild(slot);
    });
    return child;
  }

  /// Forces a synchronous layout pass on this Pane. Callers that need a
  /// slot's real measured size *now* (e.g. scroll-to-message in a chat
  /// that hasn't laid out far-back history yet) set up a per-subclass
  /// "measure request" field, then invoke this — the next [performLayout]
  /// observes the field and measures the requested slots inline. No
  /// extra frame is scheduled.
  void flushLayoutSync() {
    final owner = renderer?.owner;
    if (owner == null) return;
    renderer!.markNeedsLayout();
    owner.flushLayout();
  }

  /// Tears [slot] down from inside a layout callback.
  void invokeLayoutRemove(Object? slot) {
    if (element == null) return;
    renderer?.invokeLayoutCallback((constraints) {
      removeSlotElement(slot);
    });
  }

  /// Deactivates [slot]'s element and forgets its widget.
  void removeSlotElement(Object? slot) {
    final element = this.element;
    if (element == null) return;
    elements.remove(slot)?.pipe(element.deactivateChild);
    widgets.remove(slot);
  }

  /// Binds this pane to [element], which from here on manages its children.
  void mountElement(Element? parent, Object? newSlot, PaneElement element) {
    this.element = element;
  }

  /// Drops every child and unbinds this pane from its element.
  void unmountElement() {
    for (final child in renderBoxes.values) {
      renderer?.dropChild(child);
    }
    renderBoxes.clear();
    elements.clear();
    widgets.clear();

    element = null;
  }

  /// Inflates or updates [slot]'s element and returns its render box. An
  /// [itemBuilder] that throws leaves the slot as it was and yields `null`.
  RenderBox? buildChild(Object? slot) {
    final element = this.element;
    if (element == null) return null;

    element.owner!.buildScope(element, () {
      Widget newWidget;
      try {
        newWidget = itemBuilder(element, slot);
      } catch (e) {
        return;
      }

      final oldElement = elements[slot];
      final oldWidget = widgets[slot];
      if (oldElement == null) {
        final newElement = element.inflateWidget(newWidget, slot);
        elements[slot] = newElement;
        widgets[slot] = newWidget;
      } else if (oldWidget != null && Widget.canUpdate(oldWidget, newWidget)) {
        oldElement.update(newWidget);
        widgets[slot] = newWidget;
      } else {
        element.deactivateChild(oldElement);
        final newElement = element.inflateWidget(newWidget, slot);
        elements[slot] = newElement;
        widgets[slot] = newWidget;
      }
    });
    return elements[slot]?.renderObject as RenderBox?;
  }

  /// Drops [child] from the slot bookkeeping without deactivating it.
  void forgetChildElement(Element child) {
    elements.removeWhere((_, value) => value == child);
  }
}

/// Mounts a [Pane] as the viewport of a [Scrollable].
class PaneView extends StatelessWidget {
  /// Binds the pane to the scroll position that drives it.
  const PaneView({
    required this.controller,
    required this.scrollController,
    this.scrollPhysics,
    super.key,
  });

  /// The pane that lays out and paints the viewport.
  final Pane controller;

  /// Scroll position [controller] reads.
  final ScrollController scrollController;

  /// Physics of the enclosing [Scrollable]; platform default when omitted.
  final ScrollPhysics? scrollPhysics;

  /// Builds the viewport the [Scrollable] hosts.
  Widget buildViewport(BuildContext context, ViewportOffset offset) {
    return PaneViewport(controller: controller);
  }

  @override
  Widget build(BuildContext context) {
    return Scrollable(
      controller: scrollController,
      physics: scrollPhysics,
      viewportBuilder: buildViewport,
    );
  }
}

/// The widget a [Pane] inflates to: it creates the pane's element and
/// render box, and rebinds them when the pane is swapped.
class PaneViewport extends RenderObjectWidget {
  /// Binds the pane this widget mounts.
  const PaneViewport({
    required this.controller,
    super.key,
  });

  /// The pane that owns layout and paint.
  final Pane controller;

  @override
  RenderObjectElement createElement() {
    return PaneElement(this, controller);
  }

  @override
  RenderObject createRenderObject(BuildContext context) {
    return PaneRender(controller: controller);
  }

  @override
  void updateRenderObject(
      BuildContext context, covariant PaneRender renderObject) {
    renderObject.controller = controller;
  }
}

/// Element of a [PaneViewport]. Every child-management call is forwarded to
/// the pane, which decides which slots exist.
class PaneElement extends RenderObjectElement {
  /// Binds the element to the pane it forwards to.
  PaneElement(super.widget, this._controller);

  Pane _controller;

  /// The pane this element forwards child management to.
  Pane get controller => _controller;

  @override
  void insertRenderObjectChild(
      covariant RenderBox child, covariant Object? slot) {
    controller.insertRenderObjectChild(this, child, slot);
  }

  @override
  void moveRenderObjectChild(covariant RenderObject child,
      covariant Object? oldSlot, covariant Object? newSlot) {
    controller.moveRenderObjectChild(this, child, oldSlot, newSlot);
  }

  @override
  void removeRenderObjectChild(
      covariant RenderObject child, covariant Object? slot) {
    controller.removeRenderObjectChild(this, child, slot);
  }

  @override
  void visitChildren(ElementVisitor visitor) =>
      controller.visitChildrenElement(visitor);

  @override
  void deactivateChild(Element child) => super.deactivateChild(child);

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    controller.mountElement(parent, newSlot, this);
  }

  @override
  void unmount() {
    controller.unmountElement();
    super.unmount();
  }

  @override
  void update(covariant PaneViewport newWidget) {
    final oldController = _controller;
    final newController = newWidget.controller;
    if (oldController != newController) {
      oldController.unmountElement();
      _controller = newController;
      newController.mountElement(null, null, this);
    }
    super.update(newWidget);
  }

  @override
  void forgetChild(Element child) {
    controller.forgetChildElement(child);
    super.forgetChild(child);
  }

  @override
  Element inflateWidget(Widget newWidget, Object? newSlot) =>
      super.inflateWidget(newWidget, newSlot);

  @override
  PaneRender get renderObject => super.renderObject as PaneRender;

  @override
  PaneViewport get widget => super.widget as PaneViewport;
}

/// Render box of a [PaneViewport]. It is sized by its parent and delegates
/// layout, paint, and hit testing to the pane.
class PaneRender extends RenderBox {
  /// Binds the render box to the pane it delegates to.
  PaneRender({
    required this._controller,
  });

  Pane _controller;

  /// The pane this render box delegates to.
  Pane get controller => _controller;

  /// Swaps the pane, moving the children's pipeline attachment with it.
  set controller(Pane value) {
    if (_controller == value) return;
    if (attached) {
      _controller.detachPipeline();
      _controller.renderer = null;
    }
    _controller = value;
    if (attached) {
      _controller.attachPipeline(owner!);
      _controller.renderer = this;
      markNeedsLayout();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.attachPipeline(owner);
    _controller.renderer = this;
  }

  @override
  void detach() {
    super.detach();
    _controller.detachPipeline();
    _controller.renderer = null;
  }

  @override
  void adoptChild(RenderObject child) => super.adoptChild(child);

  @override
  void dropChild(RenderObject child) => super.dropChild(child);

  @override
  void setupParentData(covariant RenderObject child) {
    //no-op
  }

  @override
  bool get sizedByParent => true;

  @override
  void performResize() {
    size = constraints.biggest;
  }

  @override
  void performLayout() {
    if (controller.renderer == null) return;
    controller.performLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (controller.renderer == null) return;
    controller.paint(context, offset);
  }

  @override
  bool hitTestSelf(Offset position) => controller.hitTestSelf(position);

  @override
  void invokeLayoutCallback<T extends Constraints>(
          LayoutCallback<T> callback) =>
      super.invokeLayoutCallback(callback);

  @override
  bool hitTestChildren(
    BoxHitTestResult result, {
    required Offset position,
  }) =>
      controller.hitTestChildren(result, position);

  @override
  void visitChildren(RenderObjectVisitor visitor) =>
      controller.visitChildrenRender(visitor);

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    assert(child.parent == this);
    controller.applyPaintTransform(child, transform);
  }

  @override
  List<DiagnosticsNode> debugDescribeChildren() =>
      controller.debugDescribeChildren();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    controller.debugFillProperties(properties);
  }
}
