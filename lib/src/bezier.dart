import 'dart:math';
import 'dart:ui';

double bezierLength(Bezier bezier, [double steps = 10]) {
  assert(bezier != null && steps != 0);
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

abstract class Bezier {
  Offset point(double t);

  double get length => bezierLength(this);
}

class LinearBezier extends Bezier {
  Offset p0, p1;

  LinearBezier(this.p0, this.p1);

  Offset point(double t) {
    return p0 + (p1 - p0) * t;
  }

  double get length => (p1 - p0).distance;
}

class QuadraticBezier extends Bezier {
  double _quadraticBezier(double t, double p0, double p1, double p2) {
    //final lt = 1 - t;
    //return lt * (lt * p0 + t * p1) + t * (lt * p1 + t * p2);
    //return pow(1 - t, 2) * p0 + 2 * (1 - t) * t * p1 + pow(t, 2) * p2;
    return p1 + pow(1 - t, 2) * (p0 - p1) + pow(t, 2) * (p2 - p1);
  }

  Offset p0, p1, p2;

  QuadraticBezier(this.p0, this.p1, this.p2);

  Offset point(double t) {
    return Offset(
      _quadraticBezier(t, p0.dx, p1.dx, p2.dx),
      _quadraticBezier(t, p0.dy, p1.dy, p2.dy),
    );
  }
}

class CubicBezier extends Bezier {
  double _cubicBezier(double t, double p0, double p1, double p2, double p3) {
    return pow(1 - t, 3) * p0 +
        3 * t * pow(1 - t, 2) * p1 +
        3 * pow(t, 2) * (1 - t) * p2 +
        pow(t, 3) * p3;
  }

  Offset p0, p1, p2, p3;

  CubicBezier(this.p0, this.p1, this.p2, this.p3);

  Offset point(double t) => Offset(
        _cubicBezier(t, p0.dx, p1.dx, p2.dx, p3.dx),
        _cubicBezier(t, p0.dy, p1.dy, p2.dy, p3.dy),
      );
}

class PathBezier extends Bezier {
  double _length = 0;

  double get length => _length;

  List<Bezier> _curves = [];
  List<double> _lens = [];

  final Offset p0;
  Offset _p0;

  PathBezier(this.p0) : _p0 = p0;

  static PathBezier roundedRect(RRect rrect) {
    return PathBezier(Offset(rrect.left + rrect.tlRadiusX, rrect.top))
      ..lineTo(Offset(rrect.right - rrect.trRadiusX, rrect.top))
      ..quadTo(
          Offset(rrect.right, rrect.top), Offset(rrect.right, rrect.trRadiusY))
      ..lineTo(Offset(rrect.right, rrect.bottom - rrect.brRadiusY))
      ..quadTo(Offset(rrect.right, rrect.bottom),
          Offset(rrect.right - rrect.brRadiusX, rrect.bottom))
      ..lineTo(Offset(rrect.left + rrect.brRadiusX, rrect.bottom))
      ..quadTo(Offset(rrect.left, rrect.bottom),
          Offset(rrect.left, rrect.bottom - rrect.blRadiusY))
      ..lineTo(Offset(rrect.left, rrect.top + rrect.tlRadiusX))
      ..quadTo(Offset(rrect.left, rrect.top),
          Offset(rrect.left + rrect.tlRadiusX, rrect.top));
  }

  _add(Bezier bezier, Offset pn) {
    _curves.add(bezier);
    final bl = bezierLength(bezier);
    _lens.add(bl);
    _length += bl;
    _p0 = pn;
  }

  lineTo(Offset p1) => _add(LinearBezier(_p0, p1), p1);

  quadTo(Offset p1, Offset p2) => _add(QuadraticBezier(_p0, p1, p2), p2);

  cubeTo(Offset p1, Offset p2, Offset p3) =>
      _add(CubicBezier(_p0, p1, p2, p3), p3);

  relativeLineTo(Offset p1) => lineTo(
        p1 + _p0,
      );

  relativeQuadTo(Offset p1, Offset p2) => quadTo(
        p1 + p0,
        p1 + p2 + p0,
      );

  relativeCubeTo(Offset p1, Offset p2, Offset p3) => cubeTo(
        p0 + p1,
        p0 + p1 + p2,
        p0 + p1 + p2 + p3,
      );

  Offset point(double t) {
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
