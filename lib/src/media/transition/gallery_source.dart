import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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

  /// Corner shape applied outside the captured image.
  BorderRadius get borderRadius;

  /// Current image pixels, cover-fitted to [currentRect] by the flight.
  /// The caller owns the image; null means no pixels are available.
  Future<ui.Image?> snapshot();
}

/// A concrete [GallerySource] backed by a [RepaintBoundary] reachable via
/// [boundaryKey]. Suitable for any widget; the chat-side
/// `ChatMessageBubbleImageSource` (Phase 13 / chat integration) wraps its
/// image in a [RepaintBoundary] keyed by this implementation.
class RepaintBoundaryGallerySource implements GallerySource {
  /// Creates the source over [boundaryKey].
  RepaintBoundaryGallerySource(
    this.boundaryKey, {
    this.borderRadius = BorderRadius.zero,
  });

  @override
  final BorderRadius borderRadius;

  /// Key of the [RepaintBoundary] that is measured and captured.
  final GlobalKey boundaryKey;

  @override
  Rect? get currentRect {
    final renderObject = boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return null;
    if (!renderObject.hasSize) return null;
    return MatrixUtils.transformRect(
      renderObject.getTransformTo(null),
      Offset.zero & renderObject.size,
    );
  }

  @override
  Future<ui.Image?> snapshot() {
    final renderObject = boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return SynchronousFuture(null);
    try {
      return SynchronousFuture(renderObject.toImageSync(pixelRatio: 1.0));
    } catch (_) {
      // Unpainted boundaries have no layer to capture.
      return SynchronousFuture(null);
    }
  }
}
