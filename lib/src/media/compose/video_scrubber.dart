import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/compose/compose_entry.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/src/media/video_edit_values.dart';
import 'package:ux/ux.dart';
import 'package:ux/file.dart';
import 'package:ux/log.dart';

/// Telegram-style video trim scrubber + mute toggle
/// (`MediaScrubberComponent`): a thumbnail strip with 14pt draggable
/// trim handles, dimmed outside the selected range, and a playhead
/// cursor tracking the preview. Dragging a handle pauses playback and
/// scrubs the player to that boundary; release resumes the trim-looped
/// preview. Minimum trim length is 1s.
///
/// Writes flow through [ComposeEntry.setVideoEdit]; a full-range trim
/// stores null bounds so an untouched scrubber means "no edits".
class VideoTrimScrubber extends StatefulWidget {
  /// Creates the scrubber of [entry]'s video.
  const VideoTrimScrubber({
    super.key,
    required this.entry,
    required this.duration,
  });

  /// The video entry whose trim this edits.
  final ComposeEntry entry;

  /// Source duration, from the initialized preview controller.
  final Duration duration;

  @override
  State<VideoTrimScrubber> createState() => _VideoTrimScrubberState();
}

/// Telegram's `handleWidth`.
const double _kHandleWidth = 14;

const double _kStripHeight = 40;

/// Telegram's chat-video minimum trim length.
const Duration _kMinTrim = Duration(seconds: 1);

const int _kThumbCount = 10;

class _VideoTrimScrubberState extends State<VideoTrimScrubber> {
  List<Uint8List?>? _thumbs;
  _DragTarget? _drag;
  bool _wasPlayingBeforeDrag = false;

  @override
  void initState() {
    super.initState();
    widget.entry.addListener(_relayout);
    widget.entry.videoController?.addListener(_relayout);
    _loadThumbs();
  }

  @override
  void didUpdateWidget(VideoTrimScrubber old) {
    super.didUpdateWidget(old);
    if (old.entry != widget.entry) {
      old.entry.removeListener(_relayout);
      old.entry.videoController?.removeListener(_relayout);
      widget.entry.addListener(_relayout);
      widget.entry.videoController?.addListener(_relayout);
      _thumbs = null;
      _loadThumbs();
    }
  }

  @override
  void dispose() {
    widget.entry.removeListener(_relayout);
    widget.entry.videoController?.removeListener(_relayout);
    super.dispose();
  }

  void _relayout() {
    if (mounted) setState(() {});
  }

  Future<void> _loadThumbs() async {
    final durationMs = widget.duration.inMilliseconds;
    if (durationMs <= 0) return;
    final timestamps = [
      for (var i = 0; i < _kThumbCount; i++)
        (durationMs * (i + 0.5) / _kThumbCount).round(),
    ];
    final thumbs = await XFiles.videoThumbnails(
      path: widget.entry.input.file.path,
      timestampsMs: timestamps,
      maxWidth: 96,
    );
    if (!mounted) return;
    setState(() => _thumbs = [for (final t in thumbs) t?.pngBytes]);
  }

  VideoEditValues get _edit => widget.entry.videoEdit;

  double get _durationMs =>
      widget.duration.inMilliseconds.toDouble().clamp(1, double.infinity);

  double get _startFraction =>
      (_edit.trimStart?.inMilliseconds ?? 0) / _durationMs;

  double get _endFraction =>
      (_edit.trimEnd?.inMilliseconds ?? _durationMs) / _durationMs;

  double get _minTrimFraction =>
      (_kMinTrim.inMilliseconds / _durationMs).clamp(0.0, 1.0);

  static final Logger _log = Log.tag('scrubber');

  void _writeTrim({double? start, double? end}) {
    final s = (start ?? _startFraction).clamp(0.0, 1.0);
    final e = (end ?? _endFraction).clamp(0.0, 1.0);
    final startMs = (s * _durationMs).round();
    final endMs = (e * _durationMs).round();
    widget.entry.setVideoEdit(
      _edit.copyWith(
        trimStart: startMs <= 0 ? null : Duration(milliseconds: startMs),
        trimEnd: endMs >= _durationMs.round()
            ? null
            : Duration(milliseconds: endMs),
        clearTrimStart: startMs <= 0,
        clearTrimEnd: endMs >= _durationMs.round(),
      ),
    );
  }

  void _onDragStart(double localX, double innerWidth) {
    final startX = _startFraction * innerWidth;
    final endX = _endFraction * innerWidth;
    // Handles get first claim (±handle width + slop); the interior
    // scrubs the playhead.
    if ((localX - startX).abs() <= _kHandleWidth + 8) {
      _drag = _DragTarget.startHandle;
    } else if ((localX - endX).abs() <= _kHandleWidth + 8) {
      _drag = _DragTarget.endHandle;
    } else if (localX > startX && localX < endX) {
      _drag = _DragTarget.playhead;
    } else {
      _drag = null;
      return;
    }
    _wasPlayingBeforeDrag =
        widget.entry.videoController?.value.isPlaying ?? false;
    widget.entry.pauseVideo();
    _onDragUpdate(localX, innerWidth);
  }

  void _onDragUpdate(double localX, double innerWidth) {
    final f = (localX / innerWidth).clamp(0.0, 1.0);
    final ctrl = widget.entry.videoController;
    switch (_drag) {
      case _DragTarget.startHandle:
        final capped = f.clamp(0.0, _endFraction - _minTrimFraction);
        _writeTrim(start: capped);
        ctrl
            ?.seekTo(Duration(milliseconds: (capped * _durationMs).round()))
            .unawaited();
      case _DragTarget.endHandle:
        final capped = f.clamp(_startFraction + _minTrimFraction, 1.0);
        _writeTrim(end: capped);
        ctrl
            ?.seekTo(Duration(milliseconds: (capped * _durationMs).round()))
            .unawaited();
      case _DragTarget.playhead:
        final capped = f.clamp(_startFraction, _endFraction);
        ctrl
            ?.seekTo(Duration(milliseconds: (capped * _durationMs).round()))
            .unawaited();
      case null:
        break;
    }
  }

  void _onDragEnd() {
    final target = _drag;
    if (target == null) return;
    _drag = null;
    if (target != _DragTarget.playhead) {
      final edit = widget.entry.videoEdit;
      _log.i(
        'trim',
        fields: {
          'durationMs': _durationMs.round(),
          'startMs': edit.trimStart?.inMilliseconds,
          'endMs': edit.trimEnd?.inMilliseconds,
        },
      );
    }
    // Only a video that was playing when the drag grabbed it resumes —
    // a paused video stays paused on its play disc (telegram gating).
    if (_wasPlayingBeforeDrag) widget.entry.resumeVideo();
  }

  @override
  Widget build(BuildContext context) {
    final position =
        widget.entry.videoController?.value.position ?? Duration.zero;
    final positionFraction = (position.inMilliseconds / _durationMs).clamp(
      0.0,
      1.0,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(space.md, space.sm, space.md, space.xs),
      child: Row(
        children: [
          _MuteButton(entry: widget.entry),
          SizedBox(width: space.sm),
          Expanded(
            child: SizedBox(
              height: _kStripHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final innerWidth = width - 2 * _kHandleWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) => _onDragStart(
                      d.localPosition.dx - _kHandleWidth,
                      innerWidth,
                    ),
                    onHorizontalDragUpdate: (d) => _onDragUpdate(
                      d.localPosition.dx - _kHandleWidth,
                      innerWidth,
                    ),
                    onHorizontalDragEnd: (_) => _onDragEnd(),
                    onHorizontalDragCancel: _onDragEnd,
                    child: CustomPaint(
                      painter: _ScrubberPainter(
                        thumbs: _thumbs,
                        startFraction: _startFraction,
                        endFraction: _endFraction,
                        positionFraction: positionFraction,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _DragTarget { startHandle, endHandle, playhead }

class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.entry});

  final ComposeEntry entry;

  @override
  Widget build(BuildContext context) {
    final muted = entry.videoEdit.muted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => entry.setVideoEdit(entry.videoEdit.copyWith(muted: !muted)),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: muted ? colors.onMedia : const Color(0x33FFFFFF),
          shape: BoxShape.circle,
        ),
        child: Icon(
          muted ? icons.volumeXmark : icons.volumeHigh,
          size: 18,
          color: muted ? const Color(0xFF000000) : colors.onMedia,
        ),
      ),
    );
  }
}

/// Paints the thumbnail strip, the dim outside the trim window, the
/// white trim frame with its two solid handles, and the playhead.
class _ScrubberPainter extends CustomPainter {
  _ScrubberPainter({
    required this.thumbs,
    required this.startFraction,
    required this.endFraction,
    required this.positionFraction,
  });

  final List<Uint8List?>? thumbs;
  final double startFraction;
  final double endFraction;
  final double positionFraction;

  static final Map<int, ui.Image> _decoded = <int, ui.Image>{};

  @override
  void paint(Canvas canvas, Size size) {
    final inner = Rect.fromLTWH(
      _kHandleWidth,
      0,
      size.width - 2 * _kHandleWidth,
      size.height,
    );

    final stripPath = RRect.fromRectAndRadius(inner, const Radius.circular(6));
    canvas.save();
    canvas.clipRRect(stripPath);
    canvas.drawRect(inner, Paint()..color = const Color(0xFF1A1A1F));
    _paintThumbs(canvas, inner);

    // Dim outside the trim window.
    final startX = inner.left + startFraction * inner.width;
    final endX = inner.left + endFraction * inner.width;
    final dim = Paint()..color = const Color(0x99000000);
    canvas.drawRect(Rect.fromLTRB(inner.left, 0, startX, size.height), dim);
    canvas.drawRect(Rect.fromLTRB(endX, 0, inner.right, size.height), dim);
    canvas.restore();

    // Trim frame: rounded white border spanning the window, with the
    // handles as solid caps extending past the strip edges.
    final frame = RRect.fromRectAndRadius(
      Rect.fromLTRB(
        startX - _kHandleWidth,
        0,
        endX + _kHandleWidth,
        size.height,
      ),
      const Radius.circular(8),
    );
    final white = Paint()..color = colors.onMedia;
    canvas.drawRRect(
      frame,
      Paint()
        ..color = colors.onMedia
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(startX - _kHandleWidth, 0, _kHandleWidth, size.height),
        topLeft: const Radius.circular(8),
        bottomLeft: const Radius.circular(8),
      ),
      white,
    );
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(endX, 0, _kHandleWidth, size.height),
        topRight: const Radius.circular(8),
        bottomRight: const Radius.circular(8),
      ),
      white,
    );

    // Handle chevron notches, telegram-style.
    final notch = Paint()
      ..color = const Color(0xFF000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final midY = size.height / 2;
    canvas.drawPath(
      Path()
        ..moveTo(startX - _kHandleWidth / 2 + 2, midY - 5)
        ..lineTo(startX - _kHandleWidth / 2 - 2, midY)
        ..lineTo(startX - _kHandleWidth / 2 + 2, midY + 5),
      notch,
    );
    canvas.drawPath(
      Path()
        ..moveTo(endX + _kHandleWidth / 2 - 2, midY - 5)
        ..lineTo(endX + _kHandleWidth / 2 + 2, midY)
        ..lineTo(endX + _kHandleWidth / 2 - 2, midY + 5),
      notch,
    );

    // Playhead — only inside the trim window.
    final clamped = positionFraction.clamp(startFraction, endFraction);
    final px = inner.left + clamped * inner.width;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(px - 1.5, 2, 3, size.height - 4),
        const Radius.circular(1.5),
      ),
      Paint()..color = colors.onMedia,
    );
  }

  void _paintThumbs(Canvas canvas, Rect inner) {
    final list = thumbs;
    if (list == null || list.isEmpty) return;
    final cellW = inner.width / list.length;
    for (var i = 0; i < list.length; i++) {
      final bytes = list[i];
      if (bytes == null) continue;
      final image = _decoded[bytes.hashCode];
      final dst = Rect.fromLTWH(inner.left + i * cellW, 0, cellW, inner.height);
      if (image != null) {
        _drawCover(canvas, image, dst);
      } else {
        _decode(bytes);
      }
    }
  }

  void _drawCover(Canvas canvas, ui.Image image, Rect dst) {
    final srcAspect = image.width / image.height;
    final dstAspect = dst.width / dst.height;
    Rect src;
    if (srcAspect > dstAspect) {
      final w = image.height * dstAspect;
      src = Rect.fromLTWH((image.width - w) / 2, 0, w, image.height.toDouble());
    } else {
      final h = image.width / dstAspect;
      src = Rect.fromLTWH(0, (image.height - h) / 2, image.width.toDouble(), h);
    }
    canvas.save();
    canvas.clipRect(dst);
    canvas.drawImageRect(image, src, dst, Paint());
    canvas.restore();
  }

  void _decode(Uint8List bytes) async {
    final key = bytes.hashCode;
    if (_decoded.containsKey(key)) return;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    // Bounded cache: strips are ~10 frames per video; evict wholesale
    // rather than tracking LRU. The next paint re-decodes on demand.
    if (_decoded.length > 100) {
      for (final img in _decoded.values) {
        img.dispose();
      }
      _decoded.clear();
    }
    _decoded[key] = frame.image;
  }

  @override
  bool shouldRepaint(covariant _ScrubberPainter old) =>
      old.thumbs != thumbs ||
      old.startFraction != startFraction ||
      old.endFraction != endFraction ||
      old.positionFraction != positionFraction;
}
