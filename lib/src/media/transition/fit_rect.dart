import 'package:flutter/widgets.dart';

/// Returns the rect inside [viewport] that an image of [contentSize]
/// occupies when fitted (aspect-preserving) and centred — the same rect
/// `ZoomableContent` lays the photo out to at fit zoom, and the same one
/// iOS animates the open/close snapshot to via
/// `contentNode.view.bounds` converted to `self.view`'s coords
/// (`ChatImageGalleryItem.swift:1014-1016`).
///
/// Returns [viewport] when [contentSize] is null or has a zero / negative
/// dimension — defensive fallback so a malformed item doesn't blow up the
/// transition.
Rect fitRect(Size? contentSize, Rect viewport) {
  if (contentSize == null ||
      contentSize.width <= 0 ||
      contentSize.height <= 0) {
    return viewport;
  }
  final scale = (viewport.width / contentSize.width)
      .clamp(0.0, double.infinity);
  final scaleH = (viewport.height / contentSize.height)
      .clamp(0.0, double.infinity);
  final fit = scale < scaleH ? scale : scaleH;
  final w = contentSize.width * fit;
  final h = contentSize.height * fit;
  return Rect.fromCenter(
    center: viewport.center,
    width: w,
    height: h,
  );
}
