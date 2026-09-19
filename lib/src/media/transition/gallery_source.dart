import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A registration that lets the gallery query a chat-side widget for its
/// current on-screen rect and a fresh snapshot. Re-queried at *open* AND
/// *close* time so chat scrolling between events is handled correctly.
///
/// Mirrors iOS's `transitionNode` closure
/// (`ChatController.swift:1424-1435`), which returns
/// `(ASDisplayNode, CGRect, () -> (UIView?, UIView?))` — a triple of the
/// source node, its rect, and a snapshot factory.
abstract class GallerySource {
  /// Bubble rect in screen (logical) coordinates. Null if scrolled off-screen.
  Rect? get currentRect;

  /// Capture a snapshot of the bubble's current visual. Returns null if the
  /// source has been disposed or is not paintable.
  Future<ui.Image?> snapshot();
}

/// A concrete [GallerySource] backed by a [RepaintBoundary] reachable via
/// [boundaryKey]. Suitable for any widget; the chat-side
/// `ChatMessageBubbleImageSource` (Phase 13 / chat integration) wraps its
/// image in a [RepaintBoundary] keyed by this implementation.
class RepaintBoundaryGallerySource implements GallerySource {
  /// Creates the source over [boundaryKey].
  RepaintBoundaryGallerySource(this.boundaryKey);

  /// Key of the [RepaintBoundary] that is measured and captured.
  final GlobalKey boundaryKey;

  @override
  Rect? get currentRect {
    final renderObject = boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return null;
    if (!renderObject.hasSize) return null;
    final origin = renderObject.localToGlobal(Offset.zero);
    return origin & renderObject.size;
  }

  @override
  Future<ui.Image?> snapshot() async {
    final renderObject = boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return null;
    try {
      return renderObject.toImageSync(pixelRatio: 1.0);
    } catch (_) {
      // Returns null when the layer hasn't been built (boundary not yet
      // painted into the scene); the hero degrades to a no-snapshot morph.
      return null;
    }
  }
}
