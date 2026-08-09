/// A mutable, inclusive interval on a single axis.
class Range {
  /// Binds the interval `[a, b]`; [a] must not exceed [b].
  Range(this.a, this.b) : assert(a <= b);

  /// Lower bound.
  double a;

  /// Upper bound.
  double b;

  /// Whether [y] falls inside the interval, bounds included.
  bool contains(double y) => a <= y && y <= b;

  /// Whether `[x0, x1]` overlaps this interval, enclosure included.
  bool intersects(double x0, double x1) {
    return contains(x0) || contains(x1) || (x0 < a && b < x1);
  }

  /// Slides both bounds by [offset] and returns this same instance.
  Range shift(double offset) {
    a += offset;
    b += offset;
    return this;
  }

  /// Grows the interval by [extent] on each side and returns this same
  /// instance.
  Range inflate(double extent) {
    a -= extent;
    b += extent;
    return this;
  }
}
