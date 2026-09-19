import 'dart:math' as math;
import 'dart:ui';

const _quarterTurn = math.pi / 2;

/// The filled background behind a block of text, over line rects that already
/// carry their horizontal padding on both edges.
///
/// Lines whose x-extents are within `2.5 × radius` of each other snap to a
/// common extent; the rest meet through concave fillets.
Path textPillPath(List<Rect> lineUsedRects) {
  final rects = List<Rect>.of(lineUsedRects);
  _snapNearEqual(rects);

  final path = Path();
  Rect? last;
  for (final cur in rects) {
    final radius = cur.height * 0.2;
    path.addRRect(RRect.fromRectAndRadius(cur, Radius.circular(radius)));
    if (last != null && (last.bottom - cur.top).abs() < 15.0) {
      _addJoins(path, last, cur, radius);
    }
    last = cur;
  }
  return path;
}

void _snapNearEqual(List<Rect> rects) {
  if (rects.length < 2) return;
  for (var i = 1; i < rects.length; i++) {
    _snapAt(rects, i, i);
  }
}

/// [maxIndex] is the forward-pass frontier: a forward snap does not walk
/// into a line the pass has not reached.
void _snapAt(List<Rect> rects, int index, int maxIndex) {
  if (rects.length < 2 || index < 1 || index > maxIndex) return;

  final doubleRadius = rects[index].height * 0.2 * 2.5;

  if (_isInsetWithin(rects[index - 1], rects[index], doubleRadius)) {
    rects[index - 1] = _xExtentOf(rects[index], rects[index - 1]);
    _snapAt(rects, index - 1, maxIndex);
  }
  if (_isInsetWithin(rects[index], rects[index - 1], doubleRadius)) {
    rects[index] = _xExtentOf(rects[index - 1], rects[index]);
    _snapAt(rects, index + 1, maxIndex);
  }
}

/// [inner] sits inside [outer] on one horizontal edge by less than [tolerance].
bool _isInsetWithin(Rect inner, Rect outer, double tolerance) =>
    (inner.left - outer.left < tolerance && inner.left > outer.left) ||
    (inner.right - outer.right > -tolerance && inner.right < outer.right);

Rect _xExtentOf(Rect source, Rect target) =>
    Rect.fromLTWH(source.left, target.top, source.width, target.height);

/// Fills the notch left where the rounded rects of [last] and [cur] stack.
void _addJoins(Path path, Rect last, Rect cur, double radius) {
  final a = Offset(cur.left, cur.top);
  final b = Offset(cur.right, cur.top);
  final c = Offset(last.left, last.bottom);
  final d = Offset(last.right, last.bottom);
  final diameter = radius * 2;

  void arc(
    Offset center,
    double start,
    double sweep, {
    bool forceMoveTo = true,
  }) => path.arcTo(
    Rect.fromCircle(center: center, radius: radius),
    start,
    sweep,
    forceMoveTo,
  );

  if (a.dx - c.dx >= diameter) {
    arc(Offset(a.dx - radius, a.dy + radius), math.pi * 1.5, _quarterTurn);
    arc(Offset(a.dx + radius, a.dy + radius), math.pi, _quarterTurn);
    path.lineTo(a.dx - radius, a.dy);
  }
  if (a.dx == c.dx) {
    final below = Offset(a.dx + radius, a.dy + radius);
    final above = Offset(a.dx + radius, a.dy - radius);
    path.moveTo(a.dx, a.dy - radius);
    path.lineTo(a.dx, a.dy + radius);
    arc(below, math.pi, _quarterTurn, forceMoveTo: false);
    arc(above, _quarterTurn, _quarterTurn, forceMoveTo: false);
  }
  if (d.dx - b.dx >= diameter) {
    arc(Offset(b.dx + radius, b.dy + radius), math.pi * 1.5, -_quarterTurn);
    arc(Offset(b.dx - radius, b.dy + radius), 0, -_quarterTurn);
    path.lineTo(b.dx + radius, b.dy);
  }
  if (d.dx == b.dx) {
    final below = Offset(b.dx - radius, b.dy + radius);
    final above = Offset(b.dx - radius, b.dy - radius);
    path.moveTo(b.dx, b.dy - radius);
    path.lineTo(b.dx, b.dy + radius);
    arc(below, 0, -_quarterTurn, forceMoveTo: false);
    arc(above, _quarterTurn, -_quarterTurn, forceMoveTo: false);
  }
  if (c.dx - a.dx >= diameter) {
    arc(Offset(c.dx - radius, c.dy - radius), _quarterTurn, -_quarterTurn);
    arc(Offset(c.dx + radius, c.dy - radius), math.pi, -_quarterTurn);
    path.lineTo(c.dx - radius, c.dy);
  }
  if (b.dx - d.dx >= diameter) {
    arc(Offset(d.dx + radius, d.dy - radius), _quarterTurn, _quarterTurn);
    arc(Offset(d.dx - radius, d.dy - radius), 0, _quarterTurn);
    path.lineTo(d.dx + radius, d.dy);
  }
}
