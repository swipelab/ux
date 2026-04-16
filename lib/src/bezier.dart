import 'dart:math';
import 'dart:ui';

/// Computes the approximate arc length of a [Bezier] curve by sampling.
double bezierLength(Bezier bezier, [double steps = 10]) {
  assert(steps != 0);
  final step = 1 / steps;
  var c = bezier.point(0);
  var length = 0.0;
  for (var t = step; t <= 1; t += step) {
    final p = bezier.point(t);
    length += (p - c).distance;
    c = p;
  }
  return length;
}

/// Base class for parametric bezier curves.
///
/// Evaluate a point on the curve with [point] at parameter `t` in [0, 1].
abstract class Bezier {
  /// Returns the point on the curve at parameter [t] (0 = start, 1 = end).
  Offset point(double t);

  /// The approximate arc length of the curve.
  double get length => bezierLength(this);
}

/// A straight line segment from [p0] to [p1].
class LinearBezier extends Bezier {
  /// The start point.
  Offset p0;

  /// The end point.
  Offset p1;

  /// Creates a linear bezier from [p0] to [p1].
  LinearBezier(this.p0, this.p1);

  @override
  Offset point(double t) {
    return p0 + (p1 - p0) * t;
  }

  @override
  double get length => (p1 - p0).distance;
}

/// A quadratic bezier curve with one control point.
class QuadraticBezier extends Bezier {
  double _quadraticBezier(double t, double p0, double p1, double p2) {
    return p1 + pow(1 - t, 2) * (p0 - p1) + pow(t, 2) * (p2 - p1);
  }

  /// The start point.
  Offset p0;

  /// The control point.
  Offset p1;

  /// The end point.
  Offset p2;

  /// Creates a quadratic bezier from [p0] to [p2] with control point [p1].
  QuadraticBezier(this.p0, this.p1, this.p2);

  @override
  Offset point(double t) {
    return Offset(
      _quadraticBezier(t, p0.dx, p1.dx, p2.dx),
      _quadraticBezier(t, p0.dy, p1.dy, p2.dy),
    );
  }
}

/// A cubic bezier curve with two control points.
class CubicBezier extends Bezier {
  double _cubicBezier(double t, double p0, double p1, double p2, double p3) {
    return pow(1 - t, 3) * p0 +
        3 * t * pow(1 - t, 2) * p1 +
        3 * pow(t, 2) * (1 - t) * p2 +
        pow(t, 3) * p3;
  }

  /// The start point.
  Offset p0;

  /// The first control point.
  Offset p1;

  /// The second control point.
  Offset p2;

  /// The end point.
  Offset p3;

  /// Creates a cubic bezier from [p0] to [p3] with control points [p1] and [p2].
  CubicBezier(this.p0, this.p1, this.p2, this.p3);

  @override
  Offset point(double t) => Offset(
        _cubicBezier(t, p0.dx, p1.dx, p2.dx, p3.dx),
        _cubicBezier(t, p0.dy, p1.dy, p2.dy, p3.dy),
      );
}

/// A composite path of multiple bezier segments.
///
/// Build a path incrementally with [lineTo], [quadTo], and [cubeTo].
/// Evaluate any point along the total path with [point].
class PathBezier extends Bezier {
  double _length = 0;

  @override
  double get length => _length;

  final List<Bezier> _curves = [];
  final List<double> _lens = [];

  /// The starting point of the path.
  final Offset p0;
  Offset _p0;

  /// Creates a path starting at [p0].
  PathBezier(this.p0) : _p0 = p0;

  /// Creates a path tracing a rounded rectangle.
  static PathBezier roundedRect(RRect rrect) {
    return PathBezier(Offset(rrect.left + rrect.width / 2, rrect.top))
      ..lineTo(Offset(rrect.right - rrect.trRadiusX, rrect.top))
      ..quadTo(Offset(rrect.right, rrect.top),
          Offset(rrect.right, rrect.top + rrect.trRadiusY))
      ..lineTo(Offset(rrect.right, rrect.bottom - rrect.brRadiusY))
      ..quadTo(Offset(rrect.right, rrect.bottom),
          Offset(rrect.right - rrect.brRadiusX, rrect.bottom))
      ..lineTo(Offset(rrect.left + rrect.brRadiusX, rrect.bottom))
      ..quadTo(Offset(rrect.left, rrect.bottom),
          Offset(rrect.left, rrect.bottom - rrect.blRadiusY))
      ..lineTo(Offset(rrect.left, rrect.top + rrect.tlRadiusX))
      ..quadTo(Offset(rrect.left, rrect.top),
          Offset(rrect.left + rrect.tlRadiusX, rrect.top))
      ..lineTo(Offset(rrect.left + rrect.width / 2, rrect.top));
  }

  void _add(Bezier bezier, Offset pn) {
    final bl = bezierLength(bezier);
    _curves.add(bezier);
    _lens.add(bl);
    _length += bl;
    _p0 = pn;
  }

  /// Appends a straight line to [p1].
  void lineTo(Offset p1) => _add(LinearBezier(_p0, p1), p1);

  /// Appends a quadratic curve with control point [p1] to endpoint [p2].
  void quadTo(Offset p1, Offset p2) =>
      _add(QuadraticBezier(_p0, p1, p2), p2);

  /// Appends a cubic curve with control points [p1], [p2] to endpoint [p3].
  void cubeTo(Offset p1, Offset p2, Offset p3) =>
      _add(CubicBezier(_p0, p1, p2, p3), p3);

  /// Appends a straight line to a point relative to the current position.
  void relativeLineTo(Offset p1) => lineTo(p1 + _p0);

  /// Appends a quadratic curve with relative control and end points.
  void relativeQuadTo(Offset p1, Offset p2) =>
      quadTo(p1 + p0, p1 + p2 + p0);

  /// Appends a cubic curve with relative control and end points.
  void relativeCubeTo(Offset p1, Offset p2, Offset p3) =>
      cubeTo(p0 + p1, p0 + p1 + p2, p0 + p1 + p2 + p3);

  @override
  Offset point(double t) {
    if (t > 1) {
      t = t - t.floor();
    }

    if (_length == 0) return p0;
    var distance = _length * t;
    var index = 0;
    while (index < _lens.length && distance > _lens[index]) {
      distance -= _lens[index];
      index++;
    }
    if (index == _lens.length) return _p0;
    return _curves[index].point(distance / _lens[index]);
  }
}
