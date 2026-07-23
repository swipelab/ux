import 'dart:async';

import 'package:flutter/services.dart';

/// Trim / mute video export over the platform media pipelines —
/// AVFoundation on Apple platforms (passthrough remux when no
/// re-encode is needed), Media3 Transformer on Android.
///
/// One [XVideoExportSession] per [start] call; progress streams in as
/// 0..1, [XVideoExportSession.done] resolves with the output metadata
/// or throws on failure, and [XVideoExportSession.cancel] aborts and
/// deletes any partial output.
class XVideoExporter {
  static const MethodChannel _channel = MethodChannel('ux/video/export');
  static const EventChannel _events = EventChannel('ux/video/export/events');

  static Stream<Map<Object?, Object?>>? _eventStream;
  static int _nextSessionId = 0;

  /// Begin an export. The request is validated natively; unsupported
  /// sources fail through [XVideoExportSession.done].
  static XVideoExportSession start(XVideoExportRequest request) {
    final id = _nextSessionId++;
    _eventStream ??= _events
        .receiveBroadcastStream()
        .cast<Map<Object?, Object?>>()
        .asBroadcastStream();

    final progress = StreamController<double>.broadcast();
    final done = Completer<XVideoExportResult>();

    late final StreamSubscription<Map<Object?, Object?>> sub;
    sub = _eventStream!.listen((event) {
      if ((event['sessionId'] as num?)?.toInt() != id) return;
      switch (event['type'] as String?) {
        case 'progress':
          final v = (event['value'] as num?)?.toDouble();
          if (v != null && !progress.isClosed) progress.add(v);
        case 'done':
          if (!done.isCompleted) {
            done.complete(XVideoExportResult(
              path: event['path'] as String,
              width: (event['width'] as num).toInt(),
              height: (event['height'] as num).toInt(),
              durationMs: (event['durationMs'] as num).toInt(),
            ));
          }
          progress.close();
          sub.cancel();
        case 'error':
          if (!done.isCompleted) {
            done.completeError(XVideoExportException(
              event['code'] as String? ?? 'export_failed',
              event['message'] as String?,
            ));
          }
          progress.close();
          sub.cancel();
      }
    });

    _channel.invokeMethod<void>('start', <String, Object?>{
      'sessionId': id,
      'path': request.path,
      'outPath': request.outPath,
      if (request.trimStartMs != null) 'trimStartMs': request.trimStartMs,
      if (request.trimEndMs != null) 'trimEndMs': request.trimEndMs,
      'removeAudio': request.removeAudio,
      if (request.transform != null) 'transform': request.transform,
      if (request.outWidth != null) 'outWidth': request.outWidth,
      if (request.outHeight != null) 'outHeight': request.outHeight,
      if (request.videoBitrate != null) 'videoBitrate': request.videoBitrate,
      if (request.overlayPath != null) 'overlayPath': request.overlayPath,
    }).catchError((Object e) {
      if (!done.isCompleted) {
        done.completeError(
          XVideoExportException('start_failed', e.toString()),
        );
      }
      progress.close();
      sub.cancel();
    });

    return XVideoExportSession._(id, progress.stream, done.future);
  }
}

/// Parameters for one export. Null trim bounds keep the source's
/// start/end; [removeAudio] drops the audio track entirely (mute).
///
/// A pure trim/mute request (no [transform]) stays a passthrough remux
/// where the platform allows. Supplying [transform] switches to the
/// re-encode path: every frame is mapped through the affine into an
/// [outWidth]×[outHeight] canvas at [videoBitrate], so the output is a
/// verbatim bake of the caller's on-screen crop/rotate/flip preview.
class XVideoExportRequest {
  /// Creates a request; see the class docs for field semantics.
  const XVideoExportRequest({
    required this.path,
    required this.outPath,
    this.trimStartMs,
    this.trimEndMs,
    this.removeAudio = false,
    this.transform,
    this.outWidth,
    this.outHeight,
    this.videoBitrate,
    this.overlayPath,
  })  : assert((transform == null) == (outWidth == null),
            'transform and outWidth/outHeight go together'),
        assert((outWidth == null) == (outHeight == null),
            'outWidth and outHeight go together'),
        assert(overlayPath == null || transform != null,
            'overlayPath requires the transform re-encode path — send the '
            'identity affine at source dims for an overlay-only export');

  /// Absolute path of the source video.
  final String path;

  /// Absolute path the exported file is written to (overwritten).
  final String outPath;

  /// Trim start in milliseconds, or null to keep the source start.
  final int? trimStartMs;

  /// Trim end in milliseconds, or null to keep the source end.
  final int? trimEndMs;

  /// Drop the audio track entirely (mute).
  final bool removeAudio;

  /// Row-major 3×3 affine mapping **source pixel** coordinates to
  /// **output pixel** coordinates (`[a,b,c, d,e,f, 0,0,1]`, 9 values;
  /// the last row is implied but sent whole for the native decoders).
  /// Null keeps the source geometry (trim/mute-only, passthrough).
  final List<double>? transform;

  /// Output width in pixels — required with [transform], else null.
  final int? outWidth;

  /// Output height in pixels — required with [transform], else null.
  final int? outHeight;

  /// Target video bitrate (bits/s) for the re-encode path. Null lets
  /// the platform choose (trim/mute passthrough never encodes video).
  final int? videoBitrate;

  /// Absolute path of a transparent PNG at the upright source's pixel
  /// dimensions, composited over every frame BEFORE [transform] is
  /// applied — caller-drawn paint strokes that must ride the crop.
  /// Requires [transform] (overlays only exist on the re-encode path).
  final String? overlayPath;
}

/// A running export. [progress] is best-effort (platform reporting
/// granularity differs); [done] is authoritative.
class XVideoExportSession {
  XVideoExportSession._(this._id, this.progress, this.done);

  final int _id;

  /// Best-effort progress, 0..1.
  final Stream<double> progress;

  /// Resolves with the output metadata, or fails with
  /// [XVideoExportException] (code `cancelled` after [cancel]).
  final Future<XVideoExportResult> done;

  /// Abort the export and delete any partial output. [done] fails
  /// with code `cancelled`.
  Future<void> cancel() =>
      XVideoExporter._channel.invokeMethod<void>('cancel', <String, Object?>{
        'sessionId': _id,
      });
}

/// Metadata of a finished export.
class XVideoExportResult {
  /// Creates a result; see the class docs.
  const XVideoExportResult({
    required this.path,
    required this.width,
    required this.height,
    required this.durationMs,
  });

  /// Path of the written file (same as the request's `outPath`).
  final String path;

  /// Rotation-corrected output width in pixels.
  final int width;

  /// Rotation-corrected output height in pixels.
  final int height;

  /// Output duration in milliseconds.
  final int durationMs;
}

/// Failure surfaced through [XVideoExportSession.done].
class XVideoExportException implements Exception {
  /// Creates an exception with a stable [code] and optional detail.
  const XVideoExportException(this.code, [this.message]);

  /// Stable machine-readable failure code (`cancelled`,
  /// `export_failed`, `no_video_track`, ...).
  final String code;

  /// Platform-provided human-readable detail, if any.
  final String? message;

  @override
  String toString() =>
      'XVideoExportException($code${message == null ? '' : ': $message'})';
}
