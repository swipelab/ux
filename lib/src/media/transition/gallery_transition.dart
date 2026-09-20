import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/src/media/timing.dart';
import 'package:ux/src/media/transition/gallery_source.dart';

/// A snapshot flight whose shell keeps its element identity across phases.
class GalleryTransition extends StatefulWidget {
  /// [snapshot] is borrowed; captured surface and destination images are owned.
  const GalleryTransition({
    super.key,
    required this.animation,
    required this.snapshot,
    required this.sourceRect,
    required this.closeSourceLookup,
    required this.child,
    this.sourceRadius = BorderRadius.zero,
    this.onStage,
    this.onDetach,
  });

  /// Route progress, from source (zero) to page (one).
  final Animation<double> animation;

  /// Visible thumbnail captured before pushing the route.
  final ui.Image? snapshot;

  /// Opening thumbnail bounds in global coordinates; absent for standalone compose.
  final Rect? sourceRect;

  /// Shape of the opening thumbnail, excluded from its captured pixels.
  final BorderRadius sourceRadius;

  /// Current mounted destination, resolved once reverse starts.
  final GallerySource? Function() closeSourceLookup;

  /// Stable shell containing [MediaFlightSurface] and [MediaFlightChrome].
  final Widget child;

  /// Acquires source ownership on the first onstage build.
  final VoidCallback? onStage;

  /// Restores source painting during removal, before the frame paints.
  final VoidCallback? onDetach;

  @override
  State<GalleryTransition> createState() => _GalleryTransitionState();
}

class _GalleryTransitionState extends State<GalleryTransition>
    with SingleTickerProviderStateMixin {
  late CurvedAnimation _progress;
  final _flight = _Flight();
  late final AnimationController _handoff =
      AnimationController(vsync: this, duration: kMediaFlightDuration ~/ 4)
        ..addListener(() {
          _flight.lateBlend = _handoff.value;
          _flight.invalidate();
        });

  @visibleForTesting
  Rect? get paintedRectForTest => _flight.lastRect;

  @visibleForTesting
  Rect? get mediaRectForTest => _flight.surface?.globalRect;

  @visibleForTesting
  Rect? get closeSourceRectForTest => _flight.closeRect;

  @override
  void initState() {
    super.initState();
    _bind();
    _flight.onLateCapture = () {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_flight.closing) _handoff.forward(from: 0);
      });
    };
  }

  void _bind() {
    _progress = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic.flipped,
    );
  }

  @override
  void didUpdateWidget(GalleryTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _progress.dispose();
      _bind();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _handoff.dispose();
    _flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.of(context)?.offstage != true) widget.onStage?.call();
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        _flight
          ..progress = _progress.value
          ..openingSnapshot = widget.snapshot
          ..sourceRect = widget.sourceRect
          ..sourceRadius = widget.sourceRadius;
        final closing =
            widget.animation.status == AnimationStatus.reverse ||
            (_flight.closing &&
                widget.animation.status == AnimationStatus.dismissed);
        if (closing && !_flight.closing) {
          _flight.beginClose(widget.closeSourceLookup());
        } else if (!closing && _flight.closing) {
          _flight.resetClose();
        }
        return _FlightScope(
          flight: _flight,
          progress: _progress.value,
          closing: _flight.closing,
          child: _FlightPaint(
            flight: _flight,
            onDetach: widget.onDetach,
            child: child!,
          ),
        );
      },
    );
  }
}

/// Background or controls that fade in place with route progress.
class MediaFlightChrome extends StatelessWidget {
  /// Creates stationary route chrome.
  const MediaFlightChrome({super.key, required this.child});

  /// The background or controls.
  final Widget child;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: _FlightScope.maybeOf(context)?.progress ?? 1,
    child: child,
  );
}

/// Current media pixels, separated from stationary background and controls.
class MediaFlightSurface extends StatelessWidget {
  /// [contentRect] is local to [child], before ancestor drag/zoom transforms.
  const MediaFlightSurface({
    super.key,
    required this.child,
    this.contentRect,
    this.enabled = true,
    this.ready = true,
  });

  /// The live media subtree, retained during the flight.
  final Widget child;

  /// Visible image bounds within the surface; defaults to its whole box.
  final Rect? Function(Size size)? contentRect;

  /// Only the current pager item participates in the flight.
  final bool enabled;

  /// False while no image pixels are available.
  final bool ready;

  @override
  Widget build(BuildContext context) => _Surface(
    flight: enabled ? _FlightScope.maybeOf(context)?.flight : null,
    contentRect: contentRect,
    ready: ready,
    child: child,
  );
}

class _FlightScope extends InheritedWidget {
  const _FlightScope({
    required this.flight,
    required this.progress,
    required this.closing,
    required super.child,
  });
  final _Flight flight;
  final double progress;
  final bool closing;

  static _FlightScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FlightScope>();

  @override
  bool updateShouldNotify(_FlightScope oldWidget) =>
      flight != oldWidget.flight ||
      progress != oldWidget.progress ||
      closing != oldWidget.closing;
}

class _Flight {
  double progress = 0;
  bool closing = false;
  bool disposed = false;
  ui.Image? openingSnapshot;
  Rect? sourceRect;
  BorderRadius sourceRadius = BorderRadius.zero;
  ui.Image? surfaceSnapshot;
  ui.Image? destinationSnapshot;
  Rect? surfaceRect;
  Rect? destinationRect;
  BorderRadius destinationRadius = BorderRadius.zero;
  Rect? lastRect;
  Rect? closeRect;
  bool captureClose = false;
  bool paintSnapshot = false;
  bool openingComplete = false;
  double closeStart = 1;
  BorderRadius closeRadius = BorderRadius.zero;
  BorderRadius lastRadius = BorderRadius.zero;
  double lastBlend = 0;
  double? interruptedBlend;
  double? captureProgress;
  double? destinationProgress;
  double lateBlend = 0;
  VoidCallback? onLateCapture;

  double get openBlend {
    final start = captureProgress;
    if (start == null) return 0;
    if (start == 1) return lateBlend;
    return ((progress - start) / (1 - start)).clamp(0.0, 1.0);
  }

  double get closeBlend {
    final start = destinationProgress;
    return start == null || start == 0
        ? 0
        : ((start - progress) / start).clamp(0.0, 1.0);
  }

  int generation = 0;
  VoidCallback? repaint;
  final surfaces = <_RenderSurface>{};
  _RenderSurface? surface;

  void invalidate() {
    for (final surface in surfaces) {
      surface.markNeedsPaint();
    }
    repaint?.call();
  }

  bool get transporting =>
      closing ||
      progress < 1 ||
      (!openingComplete && (surfaceSnapshot == null || openBlend < 1));

  void beginClose(GallerySource? source) {
    closing = true;
    closeStart = progress;
    destinationRect = source?.currentRect;
    destinationRadius = source?.borderRadius ?? BorderRadius.zero;
    closeRect = !openingComplete && paintSnapshot ? lastRect : null;
    closeRadius = closeRect != null ? lastRadius : BorderRadius.zero;
    if (closeRect != null && openingSnapshot != null) {
      interruptedBlend = lastBlend;
      captureClose = false;
    } else {
      surfaceSnapshot?.dispose();
      surfaceSnapshot = null;
      captureClose = true;
    }
    final request = ++generation;
    source
        ?.snapshot()
        .then((image) {
          if (disposed || request != generation) {
            image?.dispose();
            return;
          }
          destinationSnapshot = image;
          destinationProgress = progress;
          repaint?.call();
        })
        .catchError((Object error) {});
  }

  void resetClose() {
    generation++;
    closing = false;
    captureClose = false;
    closeRect = null;
    interruptedBlend = null;
    destinationRect = null;
    destinationProgress = null;
    destinationSnapshot?.dispose();
    destinationSnapshot = null;
  }

  void dispose() {
    disposed = true;
    generation++;
    surfaceSnapshot?.dispose();
    destinationSnapshot?.dispose();
    repaint = null;
  }
}

class _Surface extends SingleChildRenderObjectWidget {
  const _Surface({
    required this.flight,
    required this.contentRect,
    required this.ready,
    required super.child,
  });
  final _Flight? flight;
  final Rect? Function(Size)? contentRect;
  final bool ready;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSurface(flight, contentRect, ready);

  @override
  void updateRenderObject(BuildContext context, _RenderSurface renderObject) {
    renderObject
      ..flight = flight
      ..contentRect = contentRect
      ..ready = ready
      ..markNeedsPaint();
  }
}

class _RenderSurface extends RenderProxyBox {
  _RenderSurface(this._flight, this.contentRect, this.ready);
  _Flight? _flight;
  _Flight? get flight => _flight;
  set flight(_Flight? value) {
    if (value == _flight) return;
    _flight?.surfaces.remove(this);
    _flight = value;
    if (attached) _flight?.surfaces.add(this);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _flight?.surfaces.add(this);
  }

  @override
  void detach() {
    _flight?.surfaces.remove(this);
    super.detach();
  }

  Rect? get globalRect {
    if (!attached || !hasSize) return null;
    final rect = contentRect == null ? Offset.zero & size : contentRect!(size);
    return rect == null
        ? null
        : MatrixUtils.transformRect(getTransformTo(null), rect);
  }

  Rect? Function(Size)? contentRect;
  bool ready;
  final _captureLayer = LayerHandle<OffsetLayer>();

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void dispose() {
    _captureLayer.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final f = flight;
    final rect = contentRect == null ? Offset.zero & size : contentRect!(size);
    if (f == null || rect == null || rect.isEmpty) {
      super.paint(context, offset);
      return;
    }
    final global = MatrixUtils.transformRect(getTransformTo(null), rect);
    f.surfaceRect = global;
    f.surface = this;
    var hasImage = false;
    var decodedImage = false;
    void visit(RenderObject object) {
      if (object is RenderImage) {
        hasImage = true;
        decodedImage = decodedImage || object.image != null;
      }
      object.visitChildren(visit);
    }

    if (child != null) visit(child!);
    final pixelsReady = ready && (!hasImage || decodedImage);
    f.paintSnapshot = f.transporting || (!f.openingComplete && !pixelsReady);
    if (!f.paintSnapshot) {
      f.openingComplete = true;
      super.paint(context, offset);
      return;
    }
    final layer = _captureLayer.layer ??= OffsetLayer();
    layer.removeAllChildren();
    layer.offset = Offset.zero;
    final capture = _CaptureContext(layer, Offset.zero & size);
    super.paint(capture, Offset.zero);
    capture.finish();
    if (pixelsReady && (f.surfaceSnapshot == null || f.captureClose)) {
      try {
        final image = layer.toImageSync(rect);
        f.surfaceSnapshot?.dispose();
        f.surfaceSnapshot = image;
        if (!f.closing && f.captureProgress == null) {
          f.captureProgress = f.progress;
          if (f.progress == 1) f.onLateCapture?.call();
        }
        f.captureClose = false;
        f.closeRect ??= f.closing ? global : null;
      } catch (_) {
        // A platform surface can reject capture; its live pixels remain visible.
      }
    }
    final hasTransport = f.closing
        ? f.surfaceSnapshot != null
        : f.openingSnapshot != null || f.surfaceSnapshot != null;
    if (!hasTransport) {
      context.pushOpacity(offset, (255 * f.progress).round(), (
        context,
        offset,
      ) {
        layer.offset = offset;
        context.addLayer(layer);
      });
    }
  }
}

class _FlightPaint extends SingleChildRenderObjectWidget {
  const _FlightPaint({
    required this.flight,
    required this.onDetach,
    required super.child,
  });
  final _Flight flight;
  final VoidCallback? onDetach;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFlight(flight, onDetach);

  @override
  void updateRenderObject(BuildContext context, _RenderFlight renderObject) {
    renderObject
      ..onDetach = onDetach
      ..markNeedsPaint();
  }
}

class _RenderFlight extends RenderProxyBox {
  _RenderFlight(this.flight, this.onDetach) {
    flight.repaint = markNeedsPaint;
  }
  final _Flight flight;
  VoidCallback? onDetach;

  @override
  void detach() {
    onDetach?.call();
    super.detach();
  }

  @override
  void dispose() {
    flight.repaint = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final f = flight;
    final surface = f.surface?.globalRect ?? f.surfaceRect;
    if (surface == null || !f.paintSnapshot) return;
    final Rect global;
    final BorderRadius radius;
    double opacity = 1;
    if (f.closing) {
      final start = f.closeRect ?? surface;
      final target = f.destinationRect;
      final viewport = MatrixUtils.transformRect(
        getTransformTo(null),
        Offset.zero & size,
      );
      final t = f.closeStart == 0
          ? 0.0
          : (f.progress / f.closeStart).clamp(0.0, 1.0);
      if (target != null && target.overlaps(viewport)) {
        global = Rect.lerp(target, start, t)!;
        radius = BorderRadius.lerp(f.destinationRadius, f.closeRadius, t)!;
      } else {
        final scale =
            kGalleryCloseFadeShrinkScale +
            (1 - kGalleryCloseFadeShrinkScale) * t;
        global = Rect.fromCenter(
          center: start.center,
          width: start.width * scale,
          height: start.height * scale,
        );
        radius = BorderRadius.zero;
        opacity = t;
      }
    } else {
      if (f.sourceRect == null) opacity = f.progress;
      global = Rect.lerp(f.sourceRect ?? surface, surface, f.progress)!;
      radius = BorderRadius.lerp(
        f.sourceRadius,
        BorderRadius.zero,
        f.progress,
      )!;
    }
    f.lastRect = global;
    f.lastRadius = radius;
    final local = MatrixUtils.transformRect(
      getTransformTo(null)..invert(),
      global,
    ).shift(offset);
    final first = f.closing
        ? (f.interruptedBlend != null ? f.openingSnapshot : f.surfaceSnapshot)
        : f.openingSnapshot ?? f.surfaceSnapshot;
    if (first == null) return;
    final second = f.closing ? f.destinationSnapshot : f.surfaceSnapshot;
    final blend = f.closing ? f.closeBlend : f.openBlend;
    f.lastBlend = blend;
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRRect(radius.toRRect(local));
    if (opacity < 1) {
      canvas.saveLayer(
        local,
        Paint()..color = Color.fromRGBO(255, 255, 255, opacity),
      );
    }
    paintImage(
      canvas: canvas,
      rect: local,
      image: first,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
    if (f.closing && f.interruptedBlend != null && f.surfaceSnapshot != null) {
      paintImage(
        canvas: canvas,
        rect: local,
        image: f.surfaceSnapshot!,
        fit: BoxFit.cover,
        opacity: f.interruptedBlend!,
        filterQuality: FilterQuality.medium,
      );
    }
    if (second != null && !identical(first, second)) {
      paintImage(
        canvas: canvas,
        rect: local,
        image: second,
        fit: BoxFit.cover,
        opacity: blend,
        filterQuality: FilterQuality.medium,
      );
    }
    if (opacity < 1) canvas.restore();
    canvas.restore();
  }
}

class _CaptureContext extends PaintingContext {
  _CaptureContext(super.layer, super.bounds);
  void finish() => stopRecordingIfNeeded();
}
