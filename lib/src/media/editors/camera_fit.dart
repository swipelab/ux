import 'package:vector_math/vector_math_64.dart' as vmath;

/// Immutable `(tx, ty, scale)` triple — a **uniform-scale + translate**
/// 2D affine, the only shape used for both the host viewport-fit
/// camera and the draw screen's local pinch/pan camera. Implements
/// `+`, `-`, `*` so `Animator<CameraFit>` can interpolate it
/// element-wise.
///
/// `vector_math.Matrix4 * double` is a *geometric scale* — it
/// multiplies the rotation/scale columns only, leaving translation
/// un-lerped. Driving an `Animator<Matrix4>` directly would snap
/// translation to target on the first tick while scale lags,
/// producing a visible "shrink-then-enlarge" detour. Animating
/// `CameraFit` instead interpolates all three fields together.
///
/// **Must be immutable**: `Animator`'s `start` captures the value
/// returned from `getter()`. If the setter mutated a shared object,
/// `start` would mutate alongside it, and subsequent ticks would
/// compute `prev + difference*curved` instead of `start +
/// difference*curved`, overshooting the target.
class CameraFit {
  /// A translation by ([tx], [ty]) and a uniform [scale].
  const CameraFit({required this.tx, required this.ty, required this.scale});

  /// `(0, 0, 0)` — the additive zero. Used as the seed for the host
  /// `cameraAnimator` before the first fit is published.
  static const CameraFit zero = CameraFit(tx: 0, ty: 0, scale: 0);

  /// `(0, 0, 1)` — the identity transform. Target for "reset to
  /// un-zoomed baseline" animations (e.g. draw screen viewerCamera
  /// on close).
  static const CameraFit identity = CameraFit(tx: 0, ty: 0, scale: 1);

  /// Translation along x.
  final double tx;
  /// Translation along y.
  final double ty;
  /// Uniform scale.
  final double scale;

  /// The affine as a matrix: scales by [scale], then translates by ([tx], [ty]).
  vmath.Matrix4 toMatrix() => vmath.Matrix4.identity()
    ..translateByDouble(tx, ty, 0, 1)
    ..scaleByDouble(scale, scale, 1, 1);

  /// Decompose a translate + uniform-scale [Matrix4]. Assumes the
  /// matrix has no rotation and `m[0] == m[5]` — true for the host
  /// camera and the draw viewer (both built by composing translate
  /// and uniform-scale only).
  factory CameraFit.fromMatrix(vmath.Matrix4 m) => CameraFit(
        tx: m.storage[12],
        ty: m.storage[13],
        scale: m.storage[0],
      );

  /// The element-wise sum.
  CameraFit operator +(CameraFit o) =>
      CameraFit(tx: tx + o.tx, ty: ty + o.ty, scale: scale + o.scale);

  /// The element-wise difference.
  CameraFit operator -(CameraFit o) =>
      CameraFit(tx: tx - o.tx, ty: ty - o.ty, scale: scale - o.scale);

  /// Every element times [s].
  CameraFit operator *(double s) =>
      CameraFit(tx: tx * s, ty: ty * s, scale: scale * s);

  @override
  bool operator ==(Object other) =>
      other is CameraFit &&
      other.tx == tx &&
      other.ty == ty &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(tx, ty, scale);
}
