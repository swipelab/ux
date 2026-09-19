import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/timing.dart';
import 'package:ux/src/media/x_media.dart';
import 'package:ux/src/media/compose/crop_screen.dart';
import 'package:ux/src/media/video_painters.dart';
import 'package:ux/src/media/compose/draw_screen.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:ux/gallery.dart';
import 'package:ux/src/media/host.dart';
import 'package:ux/src/media/video_edit_values.dart';
import 'package:ux/src/media/editors/animator.dart';
import 'package:ux/src/media/editors/camera_fit.dart';
import 'package:ux/src/media/editors/crop_image_layer.dart';
import 'package:ux/src/media/editors/draw_image_layer.dart';
import 'package:ux/src/media/editors/entity_layer.dart';
import 'package:ux/ux.dart';
import 'package:ux/file.dart';
import 'package:ux/log.dart';
import 'package:ux/video.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

/// Per-asset view-model for the media compose pipeline. Owns the
/// caption controller, viewer transform, video controller, the lazily
/// decoded source image, the persistent editor layers (vector state,
/// survives across tool re-entries), and a cached rendered preview.
///
/// Both `ComposePage` (one or many) and tests consume entries; the
/// chrome rebinds its composer + edit toolbar to the focused entry.
/// Mirrors telegram-iOS's per-item state in `TGMediaEditingContext`
/// (per-item caption + adjustments, shared chrome on top).
class ComposeEntry with Emitter {
  /// Creates the entry of [input]; [contentSize] is the picker's size hint.
  ComposeEntry({required this.input, this.sourceId, Size? contentSize})
    : _hintedContentSize = contentSize;

  /// Picker-side identity used to look up the bubble's [GallerySource]
  /// for the open / close hero-flight. Null for camera / file-pick
  /// flows that have no on-screen source to fly from / to — those
  /// fall back to the no-transition path.
  final Object? sourceId;

  /// Asset-known content dimensions, set by the picker from
  /// [XAsset.width] / `.height`. Lets the open hero-flight compute
  /// the fit-rect before [ensureSource] resolves the actual decoded
  /// image. After decode, [sourceSize] is authoritative.
  final Size? _hintedContentSize;

  /// Best-known intrinsic dimensions of the VISIBLE content: the crop
  /// rect once a crop layer exists (what the preview shows and the
  /// close-morph snapshot rasterises), the decoded source otherwise,
  /// the asset-side hint until decode.
  Size? get contentSize {
    if (sourceSize == null) return _hintedContentSize;
    return _cameraContentRect.size;
  }

  /// Screen rect (editor-surface coords) the visible content occupies
  /// at the current camera fit: [_cameraContentRect] aspect-fit and
  /// centered in [fitRect] — where the preview paints at rest. The
  /// open / close hero morphs anchor here. Null until the source is
  /// decoded and the fit rect measured.
  Rect? get contentScreenRect {
    final rect = fitRect.value;
    if (sourceSize == null || rect.isEmpty) return null;
    final content = _cameraContentRect;
    final scale = math.min(
      rect.width / content.width,
      rect.height / content.height,
    );
    return Rect.fromCenter(
      center: rect.center,
      width: content.width * scale,
      height: content.height * scale,
    );
  }

  /// The asset as picked / captured / pasted. Never mutated.
  final XMedia input;

  /// Source image decoded from `input.file`. Cached for the entry's
  /// lifetime so editor layers can paint without re-decoding. Null for
  /// `VideoMedia` (and any error during decode).
  ui.Image? _source;

  /// Persistent editor layers. Created lazily on first tool open;
  /// state lives in the layer instances themselves so it survives
  /// across re-entries. The layer's own `saveSnapshot` / `restoreSnapshot`
  /// handles tool-cancel rollback.
  ///
  /// Strokes and entities are recorded in source-space coordinates, so a
  /// re-crop only changes what is clipped away.
  CropImageLayer? cropLayer;
  /// The draw tool's strokes; absent until the draw tool first opens.
  DrawImageLayer? drawLayer;
  /// The text overlays; absent until the draw tool first opens.
  EntityLayer? entityLayer;

  /// Cached rendered preview (source + layer adjustments applied).
  /// Null when no edits have been applied yet — the preview falls
  /// back to `Image.file(input.file)`. Re-rendered after each tool
  /// apply.
  ui.Image? renderedPreview;
  bool _previewRendering = false;

  /// Where in the editor surface (scaffold-body coords) the image
  /// should fit. Each screen pushes its own rect via [setFitRect] from
  /// its `onActive` lifecycle: compose's rect excludes the floating
  /// top bar + bottom strip; tool screens' rects exclude their floating
  /// chrome. Because all three screens render the editor full-bleed in
  /// the same coord system, the matrix interpolates smoothly across
  /// transitions (both scale AND position animate, not just scale).
  late final ValueEmitter<Rect> fitRect = ValueEmitter<Rect>(Rect.zero)
    ..disposeBy(this);

  /// Host-owned viewport-fitting matrix shared across compose / crop /
  /// draw. Layers paint against this; gestures read its scale. Top-left
  /// origin: `camera · (0, 0)` lands at image-top-left in viewport
  /// space (telegram convention).
  late final ValueEmitter<vmath.Matrix4> camera = ValueEmitter<vmath.Matrix4>(
    vmath.Matrix4.zero(),
  )..disposeBy(this);

  /// Drives [camera] from prior fit → new fit on [setFitRect] when the
  /// rect was already populated (smooth slide). The very first
  /// `setFitRect` snaps without animation.
  ///
  /// Interpolates a `(tx, ty, scale)` wrapper rather than a `Matrix4`
  /// directly because vector_math's `Matrix4 * double` is a *geometric
  /// scale* (multiplies the rotation/scale columns only) — translation
  /// would jump to target on the first tick while scale lags, producing
  /// a visible "shrink-then-enlarge" detour during the compose↔tool
  /// transition.
  CameraFit _animatedFit = CameraFit.zero;
  /// Animates [camera] between fits.
  late final cameraAnimator = Animator<CameraFit>(
    getter: () => _animatedFit,
    setter: (f) {
      _animatedFit = f;
      camera.value = f.toMatrix();
    },
    curve: Curves.easeInOut,
  )..disposeBy(this);

  /// Source bitmap dims, once decoded; null until the first tool is
  /// opened (or [ensureSourceForTest] is called).
  Size? get sourceSize {
    final s = _source;
    if (s == null) return null;
    return Size(s.width.toDouble(), s.height.toDouble());
  }

  /// Update the rect into which the image should fit. Snaps the camera
  /// on the first call (rect previously zero / source not yet decoded),
  /// animates otherwise. Re-entrant: a same-rect call short-circuits.
  void setFitRect(Rect next) {
    if (fitRect.value == next) return;
    final wasEmpty = fitRect.value.isEmpty;
    fitRect.value = next;
    final src = sourceSize;
    if (src == null || next.isEmpty) return;
    final target = _fitOf(next, _cameraContentRect);
    if (wasEmpty || camera.value == vmath.Matrix4.zero()) {
      cameraAnimator.cancel();
      _animatedFit = target;
      camera.value = target.toMatrix();
    } else {
      cameraAnimator.animate(target: target);
    }
  }

  /// What the camera centers in the fit rect: the crop rect (equal to
  /// the image bounds until a crop is applied) — telegram's model,
  /// where the crop IS the visible content across compose and tools.
  Rect get _cameraContentRect {
    final src = sourceSize!;
    return cropLayer?.crop ?? (Offset.zero & src);
  }

  /// [camera] re-anchored for crop-OUTPUT-space content: the rendered
  /// image preview and the cropped-video pipeline lay out with the crop
  /// rect's top-left at their origin, so they paint through
  /// `camera · translate(crop.topLeft)` to land exactly where the
  /// camera fits the crop rect. Reduces to [camera] while uncropped.
  vmath.Matrix4 get cropOutputCamera {
    final origin = cropLayer?.crop.topLeft ?? Offset.zero;
    if (origin == Offset.zero) return camera.value;
    return camera.value.clone()
      ..translateByVector3(vmath.Vector3(origin.dx, origin.dy, 0));
  }

  /// Re-target the camera at the current fit rect + crop rect without
  /// changing either — the crop editor calls this after a handle-drag
  /// confirm / aspect snap so the (new) crop rect refills the surface.
  /// [curve]/[duration] select the animation feel (TgSpring for the
  /// telegram evenlyFill confirm).
  void refitCamera({Curve? curve, Duration? duration}) {
    final src = sourceSize;
    final rect = fitRect.value;
    if (src == null || rect.isEmpty) return;
    cameraAnimator
        .animate(
          target: _fitOf(rect, _cameraContentRect),
          curve: curve,
          duration: duration ?? kAnimation,
        )
        .unawaited();
  }

  /// Fit [content] (an image-space rect) into [rect]: uniform scale,
  /// centered — the camera maps image-space so `content` lands
  /// aspect-fit inside `rect`.
  static CameraFit _fitOf(Rect rect, Rect content) {
    final scale = math.min(
      rect.width / content.width,
      rect.height / content.height,
    );
    return CameraFit(
      tx: rect.left +
          (rect.width - content.width * scale) / 2 -
          content.left * scale,
      ty: rect.top +
          (rect.height - content.height * scale) / 2 -
          content.top * scale,
      scale: scale,
    );
  }

  /// Compose the user's compose-page pan/zoom (held by [viewerController]
  /// from the `InteractiveViewer`) into [camera] and reset the viewer to
  /// identity. Called by `ComposePage._openTool` so the tool screen's
  /// `cameraAnimator` starts from what the user is *currently looking
  /// at* — pre-fix the camera was still at the original fit and the
  /// image visibly snapped back when crop / draw mounted.
  void bakeViewerTransform() {
    final v = viewerController.value;
    final vs = v.storage[0];
    final vx = v.storage[12];
    final vy = v.storage[13];
    if (vs == 1.0 && vx == 0 && vy == 0) return;
    cameraAnimator.cancel();
    final composed = CameraFit(
      tx: vx + vs * _animatedFit.tx,
      ty: vy + vs * _animatedFit.ty,
      scale: vs * _animatedFit.scale,
    );
    _animatedFit = composed;
    camera.value = composed.toMatrix();
    viewerController.value = vmath.Matrix4.identity();
  }

  /// True when at least one tool has been applied to an IMAGE (used by
  /// the page's submit handler to decide whether to rasterise on send).
  /// A video's crop is not rasterised — it rides [videoEdit].crop to the
  /// send-time export — so this stays image-only.
  bool get hasEdits =>
      input is ImageMedia &&
      ((cropLayer?.hasAppliedEdits ?? false) ||
          (drawLayer?.hasAppliedEdits ?? false) ||
          (entityLayer?.hasAppliedEdits ?? false));

  /// The caption's text, from the host's caption controller.
  final TextEditingController composerController =
      MediaHost.current.captionController();

  /// Pinch-zoom transform of the preview.
  late final TransformationController viewerController =
      TransformationController()..addListener(_onZoomChanged);
  /// Whether the preview is zoomed in.
  final ValueNotifier<bool> isZoomed = ValueNotifier<bool>(false);

  /// Player of a video entry's preview; absent for other media, before
  /// [ensureVideoInitialized] and after [disposeVideo].
  XVideoPlayerController? videoController;
  bool _videoInitStarted = false;

  /// Eagerly decode `input.file` and cache it as [source]. Idempotent.
  /// Returns `null` for non-image media. Required by `ComposePage` so
  /// the compose-page preview can paint via the same camera matrix the
  /// tool screens use — otherwise compose's `BoxFit.contain` against
  /// the full body would land the image at a different on-screen rect
  /// than tool screens' camera-driven render, producing a visible jump
  /// (the "shrink-then-enlarge" boundary) on entering crop / draw.
  Future<ui.Image?> ensureSource() async {
    if (input is! ImageMedia) return null;
    if (_source != null) return _source;
    final decoded = await _decodeFile(input.file);
    if (disposed) {
      // Compose popped mid-decode: `dispose` already ran, so this image
      // has no owner left to release it.
      decoded?.dispose();
      return null;
    }
    _source = decoded;
    final src = sourceSize;
    if (src != null && !fitRect.value.isEmpty) {
      cameraAnimator.cancel();
      final fit = _fitOf(fitRect.value, _cameraContentRect);
      _animatedFit = fit;
      camera.value = fit.toMatrix();
    }
    notifyListeners();
    return _source;
  }

  /// Decoded source image. Null until [ensureSource] completes.
  ui.Image? get source => _source;

  /// Test hook: eagerly decode `input.file` and cache it as [source].
  @visibleForTesting
  Future<ui.Image?> ensureSourceForTest() => ensureSource();

  /// Test hook: force a preview re-render. Production code reaches
  /// `_renderPreview` indirectly via tool apply; tests need to call
  /// it after directly mutating `cropLayer` / `drawLayer`.
  @visibleForTesting
  Future<void> refreshPreviewForTest() => _renderPreview();

  /// Test hook: dispose and clear [renderedPreview]. Tests call this
  /// before a second [refreshPreviewForTest] so the new render is a
  /// distinct image (and the old one's GPU bitmap is released).
  @visibleForTesting
  void invalidatePreviewForTest() => _invalidatePreview();

  /// Test hook: decode the video crop poster exactly like
  /// [openCropEditor] does (native resolution, cached as [source]).
  @visibleForTesting
  Future<ui.Image?> ensureVideoPosterForTest() => _ensureVideoPoster();

  /// Test hook: bake strokes and text entities into [videoEdit].overlay
  /// exactly like a draw-tool apply does.
  @visibleForTesting
  Future<void> snapshotDrawOverlayForTest() => _snapshotDrawOverlay();

  /// Lazily initialise the video controller and start looping playback.
  /// Safe to call multiple times — only the first invocation kicks off
  /// the load.
  Future<void> ensureVideoInitialized() async {
    if (input is! VideoMedia || _videoInitStarted) return;
    _videoInitStarted = true;
    final ctrl = XVideoPlayerController.file(input.file);
    videoController = ctrl;
    try {
      await ctrl.initialize();
      await ctrl.setLooping(true);
      await ctrl.setVolume(videoEdit.muted ? 0 : 1);
      ctrl.addListener(_enforceTrimLoop);
      // Telegram picker parity (TGMediaPickerGalleryVideoItemView
      // setIsCurrent): only a MUTED video auto-plays; with sound the
      // poster waits under the play disc until the user taps it.
      if (videoEdit.muted) await ctrl.play();
    } catch (_) {
      // Leave the controller in its uninitialised state; the preview
      // falls back to an empty container which keeps layout stable.
    }
    notifyListeners();
  }

  /// Per-entry trim / mute state (V1 of the video-editing plan;
  /// telegram's `videoTrimRange` / `videoIsMuted`). Survives tool
  /// re-entries like the crop/draw layers; travels to the send
  /// pipeline via `ComposeResult.videoEdit`.
  VideoEditValues videoEdit = const VideoEditValues();

  static final Logger _log = Log.tag('compose');

  /// Scrubber/mute write path: stores the values, applies volume
  /// immediately, and snaps the playhead into the trim range.
  void setVideoEdit(VideoEditValues next) {
    if (videoEdit == next) return;
    // A trim arrives continuously from a scrubber drag, which logs the
    // committed range once the gesture ends; mute, crop and overlay are
    // discrete edits that each deserve a record.
    final fields = <String, Object?>{
      'trimStartMs': next.trimStart?.inMilliseconds,
      'trimEndMs': next.trimEnd?.inMilliseconds,
      'muted': next.muted,
      'crop': next.crop != null,
      'overlay': next.overlay != null,
    };
    if (next.muted == videoEdit.muted &&
        next.crop == videoEdit.crop &&
        next.overlay == videoEdit.overlay) {
      _log.d('videoEdit', fields: fields);
    } else {
      _log.i('videoEdit', fields: fields);
    }
    videoEdit = next;
    final ctrl = videoController;
    if (ctrl != null && ctrl.value.isInitialized) {
      ctrl.setVolume(next.muted ? 0 : 1).unawaited();
      final start = next.trimStart ?? Duration.zero;
      final end = next.trimEnd;
      final pos = ctrl.value.position;
      if (pos < start || (end != null && pos > end)) {
        ctrl.seekTo(start).unawaited();
      }
    }
    notifyListeners();
  }

  /// Preview playback loops inside the trim range: when the reported
  /// position leaves [videoEdit]'s bounds (either past the end, or
  /// wrapped to 0 by the native looper), snap back to the trim start.
  void _enforceTrimLoop() {
    final ctrl = videoController;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    final start = videoEdit.trimStart;
    final end = videoEdit.trimEnd;
    if (start == null && end == null) return;
    final pos = ctrl.value.position;
    final lower = start ?? Duration.zero;
    if ((end != null && pos >= end) || pos < lower) {
      ctrl.seekTo(lower).unawaited();
    }
  }

  /// Fully tear down the video controller. The page calls this on
  /// swipe-away so memory stays bounded — re-paging-to triggers a
  /// fresh `ensureVideoInitialized` and the controller is reborn.
  /// Matches telegram-iOS's `viewDidAppear` / `viewDidDisappear`
  /// gallery item lifecycle.
  Future<void> disposeVideo() async {
    final ctrl = videoController;
    if (ctrl == null) return;
    await ctrl.dispose();
    videoController = null;
    _videoInitStarted = false;
    notifyListeners();
  }

  /// Pauses the video preview.
  void pauseVideo() => videoController?.pause();
  /// Plays the video preview.
  void resumeVideo() => videoController?.play();

  /// Open the crop tool. Images crop their decoded source; videos crop a
  /// poster frame extracted at [videoEdit]'s trim start (telegram's model
  /// — the same `CropImageLayer` geometry drives the export). The crop
  /// layer is borrowed by `CropScreen.borrowed`; its state survives back
  /// on this entry. On apply, an image re-renders its preview while a
  /// video snapshots the layer geometry into [videoEdit].crop (the live
  /// player preview + send-time export read it); cancels restore the
  /// layer from its snapshot (taken on tool-open).
  Future<void> openCropEditor() async {
    final ui.Image? source = switch (input) {
      VideoMedia() => await _ensureVideoPoster(),
      ImageMedia() => await ensureSource(),
      _ => null,
    };
    if (source == null) return;
    // Telegram stops playback for the whole editing session
    // (prepareForEditing) and does NOT resume on return — the play
    // disc just comes back.
    pauseVideo();
    cropLayer ??= CropImageLayer(image: source);
    final applied = await CropScreen.borrowed(
      layer: cropLayer!,
      draw: drawLayer,
      entities: entityLayer,
      camera: camera,
      setFitRect: setFitRect,
      refitCamera: refitCamera,
    ).push();
    if (applied != true) return;
    if (input is VideoMedia) {
      final cl = cropLayer!;
      setVideoEdit(cl.hasAppliedEdits
          ? videoEdit.copyWith(crop: cropGeometryFrom(cl))
          : videoEdit.copyWith(clearCrop: true));
    } else {
      _invalidatePreview();
      await _renderPreview();
    }
  }

  /// Snapshot the crop layer's source→output geometry into a
  /// [VideoCropGeometry] — the export affine (row-major 3×3 from
  /// `exportMatrix`, whose column-major storage we index by `entry`) plus
  /// the crop output size. Dimensions are raw here; the send path clamps
  /// them to the quality tier.
  static VideoCropGeometry cropGeometryFrom(CropImageLayer layer) {
    final m = layer.exportMatrix;
    final size = layer.exportSize;
    return VideoCropGeometry(
      transform: <double>[
        m.entry(0, 0), m.entry(0, 1), m.entry(0, 3),
        m.entry(1, 0), m.entry(1, 1), m.entry(1, 3),
        0, 0, 1,
      ],
      outWidth: size.width.round(),
      outHeight: size.height.round(),
    );
  }

  /// Decode a poster frame for the video crop tool, cached as [source] so
  /// `CropImageLayer` and the shared camera fit work exactly as they do
  /// for an image. Extracted at the current trim start via
  /// `XFiles.videoThumbnail` at NATIVE resolution — the poster is the
  /// coordinate space of the crop geometry (`exportMatrix` source px),
  /// which the preview and the native exporters interpret as video
  /// pixels; a downscaled poster would shrink every crop it produces.
  /// Null on any decode/extract failure.
  Future<ui.Image?> _ensureVideoPoster() async {
    if (input is! VideoMedia) return null;
    if (_source != null) return _source;
    try {
      final thumb = await XFiles.videoThumbnail(
        path: input.file.path,
        atMs: videoEdit.trimStart?.inMilliseconds ?? 0,
        maxWidth: null,
      );
      final bytes = thumb?.pngBytes;
      if (bytes == null) return null;
      _source = await _decodeBytes(bytes);
    } catch (_) {
      return null;
    }
    if (sourceSize != null && !fitRect.value.isEmpty) {
      cameraAnimator.cancel();
      final fit = _fitOf(fitRect.value, _cameraContentRect);
      _animatedFit = fit;
      camera.value = fit.toMatrix();
    }
    notifyListeners();
    return _source;
  }

  /// Opens the draw tool over the decoded image or the video's poster frame.
  Future<void> openDrawEditor() async {
    final ui.Image? source = switch (input) {
      VideoMedia() => await _ensureVideoPoster(),
      ImageMedia() => await ensureSource(),
      _ => null,
    };
    if (source == null) return;
    pauseVideo();
    drawLayer ??= DrawImageLayer(image: source);
    entityLayer ??= EntityLayer(imageSize: sourceSize!);
    // Pass the crop layer so the draw editor's canvas IS the cropped
    // preview (source × prior strokes → crop transform → clipped).
    // Pointer coords are converted source-space via DrawGestures'
    // crop-aware path so new strokes land at the right source pixel.
    final applied = await DrawScreen.borrowed(
      layer: drawLayer!,
      crop: cropLayer,
      entities: entityLayer,
      camera: camera,
      setFitRect: setFitRect,
    ).push();
    if (applied != true) return;
    if (input is VideoMedia) {
      await _snapshotDrawOverlay();
    } else {
      _invalidatePreview();
      await _renderPreview();
    }
  }

  /// Bake strokes and text entities into a transparent source-dims PNG
  /// in the upload staging dir and snapshot it into [videoEdit].overlay —
  /// the file the native export composites over every frame. An empty
  /// overlay (no strokes, no entities) clears it. The vector state stays
  /// on [drawLayer] / [entityLayer], so re-entering the tool keeps it
  /// editable.
  Future<void> _snapshotDrawOverlay() async {
    final src = sourceSize;
    if (src == null) return;
    final hasDraw = drawLayer?.hasAppliedEdits ?? false;
    final hasEntities = entityLayer?.hasAppliedEdits ?? false;
    if (!hasDraw && !hasEntities) {
      setVideoEdit(videoEdit.copyWith(clearOverlay: true));
      return;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & src);
    if (hasDraw) drawLayer!.paintStrokesOnly(canvas, src);
    if (hasEntities) entityLayer!.paintEntitiesOnly(canvas, src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(src.width.toInt(), src.height.toInt());
    picture.dispose();
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final base = await path_provider.getTemporaryDirectory();
    final dir = io.Directory('${base.path}/banlu_uploads');
    await dir.create(recursive: true);
    final file = io.File(
        '${dir.path}/draw_${clock.now().microsecondsSinceEpoch}.png');
    await file.writeAsBytes(byteData!.buffer
        .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
    setVideoEdit(videoEdit.copyWith(
      overlay: VideoDrawOverlay(
        path: file.path,
        width: src.width.toInt(),
        height: src.height.toInt(),
      ),
    ));
  }

  void _invalidatePreview() {
    final old = renderedPreview;
    renderedPreview = null;
    notifyListeners();
    old?.dispose();
  }

  Future<void> _renderPreview() async {
    if (_previewRendering || input is! ImageMedia) return;
    _previewRendering = true;
    try {
      final source = await ensureSource();
      if (source == null) return;
      renderedPreview = await _composeLayers(source);
      notifyListeners();
    } finally {
      _previewRendering = false;
    }
  }

  /// Composite source + active layers into one [ui.Image]: source →
  /// strokes → entities, all in source-image space, then the crop
  /// transform clips + rotates / flips the result.
  Future<ui.Image> _composeLayers(ui.Image source) async {
    final hasCrop = cropLayer?.hasAppliedEdits ?? false;
    final hasDraw = drawLayer?.hasAppliedEdits ?? false;
    final hasEntities = entityLayer?.hasAppliedEdits ?? false;
    if (!hasCrop && !hasDraw && !hasEntities) return _cloneImage(source);

    // Step 1: source + strokes + entities, at source dims.
    final ui.Image step1;
    if (hasDraw || hasEntities) {
      final recorder = ui.PictureRecorder();
      final fullSize = Size(source.width.toDouble(), source.height.toDouble());
      final canvas = Canvas(recorder, Offset.zero & fullSize);
      canvas.drawImage(source, Offset.zero, Paint());
      if (hasDraw) drawLayer!.paintStrokesOnly(canvas, fullSize);
      if (hasEntities) entityLayer!.paintEntitiesOnly(canvas, fullSize);
      final picture = recorder.endRecording();
      step1 = await picture.toImage(source.width, source.height);
      picture.dispose();
    } else {
      step1 = await _cloneImage(source);
    }

    // Step 2: apply crop transform to step 1. The crop layer's
    // imageTransform + crop rect are in source-image space, so feeding
    // step 1 (same dims as source) maps correctly.
    if (!hasCrop) return step1;

    final cl = cropLayer!;
    final outSize = cl.exportSize;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & outSize);
    cl.paintExportOf(canvas, outSize, step1);
    final picture = recorder.endRecording();
    final step2 = await picture.toImage(
      outSize.width.toInt(),
      outSize.height.toInt(),
    );
    picture.dispose();
    step1.dispose();
    return step2;
  }

  /// In-memory composite for the send pipeline. Returns the cached
  /// [renderedPreview] when available (the common case — tool
  /// applies eagerly rasterise into it); falls back to a fresh
  /// `_renderPreview()` if the user tapped Send before the
  /// preview finished. Null when there are no edits — callers
  /// upload [input] as-is.
  ///
  /// The PNG encode + disk write that used to live here moved to
  /// `OutgoingImageFromComposite` (kicked off eagerly in its
  /// constructor), so compose pops without touching the filesystem.
  Future<ui.Image?> composedImage() async {
    if (!hasEdits) return null;
    if (renderedPreview != null) return renderedPreview;
    await _renderPreview();
    return renderedPreview;
  }

  /// Final visual image bytes for avatar-style callers. Unlike
  /// [composedImage], this also rasterises an unedited source image so
  /// the uploaded avatar matches the preview instead of any raw file
  /// metadata quirks.
  Future<Uint8List> resolveImageBytes() async {
    if (input is! ImageMedia) return input.file.readAsBytes();
    final image = await composedImage() ?? await ensureSource();
    if (image == null) return input.file.readAsBytes();
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
  }

  Future<ui.Image?> _decodeFile(io.File f) async {
    try {
      return await _decodeBytes(await f.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image> _decodeBytes(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// Clone a [ui.Image] so the caller can dispose it without affecting
  /// the original. Re-encodes via a tiny picture recorder — no isolate
  /// roundtrip, no PNG encode.
  Future<ui.Image> _cloneImage(ui.Image src) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(src, Offset.zero, Paint());
    final picture = recorder.endRecording();
    final out = await picture.toImage(src.width, src.height);
    picture.dispose();
    return out;
  }

  void _onZoomChanged() {
    final next = viewerController.value.getMaxScaleOnAxis() > 1.01;
    if (next != isZoomed.value) isZoomed.value = next;
  }

  @override
  void dispose() {
    _source?.dispose();
    renderedPreview?.dispose();
    cropLayer?.dispose();
    drawLayer?.dispose();
    entityLayer?.dispose();
    viewerController.removeListener(_onZoomChanged);
    viewerController.dispose();
    isZoomed.dispose();
    videoController?.dispose();
    composerController.dispose();
    super.dispose();
  }
}

/// Stateless preview widget. For [ImageMedia], paints the source
/// (or `renderedPreview` if set) via the host camera matrix — the
/// SAME matrix tool screens use — so transitioning compose → crop /
/// draw is a continuous animation of one matrix, with no boundary
/// jump. For [VideoMedia], renders the player when initialised.
class ComposeEntryView extends StatelessWidget {
  /// Creates the preview of [entry].
  const ComposeEntryView({required this.entry, super.key});

  /// The entry shown.
  final ComposeEntry entry;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) {
        return switch (entry.input) {
          ImageMedia() => InteractiveViewer(
            transformationController: entry.viewerController,
            maxScale: 4,
            child: _ImagePreview(entry: entry),
          ),
          VideoMedia() => _buildVideo(entry),
          // FileMedia / AudioMedia never reach ComposeEntry — filtered
          // at the chat dispatch layer before _composeAndSend.
          _ => SizedBox.expand(),
        };
      },
    );
  }

  Widget _buildVideo(ComposeEntry entry) {
    final ctrl = entry.videoController;
    if (ctrl == null || !ctrl.value.isInitialized) return SizedBox.expand();
    Widget player = ctrl.buildPlayer();
    // Paint strokes and text entities live over the frames, in the same
    // source-space box the crop affine transforms — video and overlay
    // crop together, exactly like the export composites them.
    final dl = entry.drawLayer;
    final el = entry.entityLayer;
    final overlaySrc = entry.sourceSize;
    final hasDraw = dl != null && dl.hasAppliedEdits;
    final hasEntities = el != null && el.hasAppliedEdits;
    if ((hasDraw || hasEntities) && overlaySrc != null) {
      player = Stack(
        fit: StackFit.expand,
        children: [
          player,
          IgnorePointer(
            child: CustomPaint(
              painter: _VideoDrawOverlayPainter(
                draw: hasDraw ? dl : null,
                entities: hasEntities ? el : null,
                sourceSize: overlaySrc,
              ),
            ),
          ),
        ],
      );
    }
    final crop = entry.videoEdit.crop;
    final video = crop == null
        ? Center(
            child: AspectRatio(
              aspectRatio: ctrl.value.aspectRatio,
              child: player,
            ),
          )
        : CroppedVideoPreview(
            entry: entry,
            crop: crop,
            child: player,
          );
    return ComposePlayOverlay(controller: ctrl, child: video);
  }
}

/// Telegram picker-parity playback gate over the compose video preview
/// (`TGMediaPickerGalleryVideoItemView`): while paused, a centered
/// half-black disc with the gallery's play triangle sits on the poster;
/// tapping it plays. While playing the disc hides and a tap anywhere on
/// the video pauses (TG's `singleTap → pausePressed`).
class ComposePlayOverlay extends StatelessWidget {
  /// Creates the gate over [child].
  const ComposePlayOverlay({
    required this.controller,
    required this.child,
    super.key,
  });

  /// The player the gate plays and pauses.
  final XVideoPlayerController controller;
  /// The video preview.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<XVideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final playing = value.isPlaying;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: playing ? () => controller.pause().unawaited() : null,
          child: Stack(
            children: [
              child,
              if (!playing)
                Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => controller.play().unawaited(),
                    child: Container(
                      width: kCenterStatusDiameter,
                      height: kCenterStatusDiameter,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0x80000000),
                      ),
                      child: CustomPaint(
                        painter: PlayTrianglePainter(colors.onMedia),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Paints the entry's strokes and text entities over the video preview.
/// The canvas is scaled from the widget box to [sourceSize] so the
/// overlay (recorded in source pixels) lands on the same frame pixels
/// the export composites it onto.
class _VideoDrawOverlayPainter extends CustomPainter {
  _VideoDrawOverlayPainter({
    this.draw,
    this.entities,
    required this.sourceSize,
  }) : super(repaint: Listenable.merge([?draw, ?entities]));

  final DrawImageLayer? draw;
  final EntityLayer? entities;
  final Size sourceSize;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(
        size.width / sourceSize.width, size.height / sourceSize.height);
    draw?.paintStrokesOnly(canvas, sourceSize);
    entities?.paintEntitiesOnly(canvas, sourceSize);
  }

  @override
  bool shouldRepaint(covariant _VideoDrawOverlayPainter old) =>
      old.draw != draw ||
      old.entities != entities ||
      old.sourceSize != sourceSize;
}

/// Live compose preview of a cropped video: [child] (the player) is laid
/// out at the entry's poster dimensions — the pixel space the crop
/// geometry was authored on (not the controller-reported video size,
/// which some decoders report pre-rotation; a crop implies the poster is
/// decoded) — run through the same source→output affine the export bakes
/// ([VideoCropGeometry.transform]) and clipped to the crop output rect,
/// so preview and export show the identical crop. The clipped result is
/// placed on screen by [ComposeEntry.cropOutputCamera] — the same
/// placement the image preview paints with, so image and video crops
/// center identically and ride the compose↔tool camera animation
/// together.
class CroppedVideoPreview extends StatelessWidget {
  /// Creates the cropped preview of [child].
  const CroppedVideoPreview({
    required this.entry,
    required this.crop,
    required this.child,
    super.key,
  });

  /// The video entry, which places the crop on screen.
  final ComposeEntry entry;
  /// The crop applied to the video.
  final VideoCropGeometry crop;
  /// The uncropped video.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sourceSize = entry.sourceSize!;
    return ListenableBuilder(
      listenable: entry.camera,
      builder: (context, _) => Transform(
        transform: entry.cropOutputCamera,
        child: OverflowBox(
          minWidth: 0,
          maxWidth: double.infinity,
          minHeight: 0,
          maxHeight: double.infinity,
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: crop.outWidth.toDouble(),
              height: crop.outHeight.toDouble(),
              child: Transform(
                transform:
                    Matrix4.fromFloat64List(crop.transformColumnMajor4x4),
                child: OverflowBox(
                  minWidth: 0,
                  maxWidth: double.infinity,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: sourceSize.width,
                    height: sourceSize.height,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the entry's image via [ComposeEntry.camera] — same matrix
/// the tool screens use, so transitioning compose ↔ crop / draw is
/// one continuous interpolation. Falls back to `Image.file` until the
/// source is decoded.
class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.entry});
  final ComposeEntry entry;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  @override
  void initState() {
    super.initState();
    widget.entry.ensureSource();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.entry, widget.entry.camera]),
      builder: (ctx, _) {
        final image = widget.entry.renderedPreview ?? widget.entry.source;
        final cam = widget.entry.camera.value;
        if (image == null || cam == vmath.Matrix4.zero()) {
          // Source not yet decoded / camera not yet measured — paint
          // nothing rather than a wrong-position fallback. The
          // ComposePage.onActive → setFitRect chain is fast enough
          // that this is at most one frame.
          return SizedBox.expand();
        }
        // The rendered preview is rasterised in crop-output space (its
        // origin is the crop rect's top-left); the raw source fallback
        // is in source space.
        final matrix = widget.entry.renderedPreview != null
            ? widget.entry.cropOutputCamera
            : cam;
        return CustomPaint(
          painter: _CameraImagePainter(image: image, camera: matrix),
          size: Size.infinite,
        );
      },
    );
  }
}

class _CameraImagePainter extends CustomPainter {
  _CameraImagePainter({required this.image, required this.camera});

  final ui.Image image;
  final vmath.Matrix4 camera;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.transform(camera.storage);
    canvas.drawImage(image, Offset.zero, Paint());
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CameraImagePainter old) =>
      old.image != image || old.camera != camera;
}
