import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import 'package:ux/src/screen/x_screen_sources.dart';

/// Production [XScreenSourcesBackend]: `ux/screen_sources` for commands.
class MethodChannelXScreenSourcesBackend implements XScreenSourcesBackend {
  /// Creates a backend bound to the `ux/screen_sources` channel.
  MethodChannelXScreenSourcesBackend();

  static const _channel = MethodChannel('ux/screen_sources');

  static const _maxThumbnailEdge = 4096;

  static const _sourceKeys = {
    'id',
    'kind',
    'title',
    'applicationName',
    'sourceWidth',
    'sourceHeight',
    'thumbnailPng',
  };

  @override
  XScreenCaptureMode? get captureMode => kIsWeb
      ? null
      : switch (defaultTargetPlatform) {
          TargetPlatform.macOS => XScreenCaptureMode.pickerDriven,
          TargetPlatform.android ||
          TargetPlatform.iOS =>
            XScreenCaptureMode.consentDriven,
          _ => null,
        };

  @override
  bool get supported =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.macOS || TargetPlatform.android => true,
        _ => false,
      };

  @override
  Future<bool> available() async {
    _requireSupported();
    return _invoke<bool>('available');
  }

  @override
  Future<bool> hasPermission() async {
    _requireMode(XScreenCaptureMode.pickerDriven);
    return _invoke<bool>('hasPermission');
  }

  @override
  Future<bool> requestPermission() async {
    _requireMode(XScreenCaptureMode.pickerDriven);
    return _invoke<bool>('requestPermission');
  }

  @override
  Future<void> startShare({
    required String notificationTitle,
    String? notificationText,
  }) async {
    _requireMode(XScreenCaptureMode.consentDriven);
    if (notificationTitle.isEmpty) {
      throw ArgumentError.value(
        notificationTitle,
        'notificationTitle',
        'must not be empty',
      );
    }
    await _call('startShare', {
      'notificationTitle': notificationTitle,
      'notificationText': notificationText,
    });
  }

  @override
  Future<void> stopShare() async {
    _requireMode(XScreenCaptureMode.consentDriven);
    await _call('stopShare');
  }

  @override
  Future<List<XScreenSource>> list({
    required Set<String> allowedDisplayIds,
    required Set<String> allowedWindowIds,
    int thumbnailWidth = 320,
    int thumbnailHeight = 180,
  }) async {
    _requireMode(XScreenCaptureMode.pickerDriven);
    _requireEdge(thumbnailWidth, 'thumbnailWidth');
    _requireEdge(thumbnailHeight, 'thumbnailHeight');
    final raw = await _invoke<List<Object?>>('list', {
      'allowedDisplayIds': allowedDisplayIds.toList(growable: false),
      'allowedWindowIds': allowedWindowIds.toList(growable: false),
      'thumbnailWidth': thumbnailWidth,
      'thumbnailHeight': thumbnailHeight,
    });
    return raw.map(_decodeSource).toList(growable: false);
  }

  Future<Object?> _call(String method,
      [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (e) {
      throw XScreenSourcesException(e.code, e.message);
    }
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    final result = await _call(method, arguments);
    if (result is! T) {
      throw _invalid('result', 'expected $T, got ${result.runtimeType}');
    }
    return result;
  }

  void _requireSupported() {
    if (supported) return;
    throw XScreenSourcesException('unsupported', '$defaultTargetPlatform');
  }

  void _requireMode(XScreenCaptureMode mode) {
    _requireSupported();
    if (captureMode == mode) return;
    throw XScreenSourcesException(
      'unsupported',
      '$defaultTargetPlatform is ${captureMode?.name}',
    );
  }

  static void _requireEdge(int value, String name) {
    if (value > 0 && value <= _maxThumbnailEdge) return;
    throw ArgumentError.value(value, name, 'must be 1..$_maxThumbnailEdge');
  }

  static XScreenSource _decodeSource(Object? raw) {
    if (raw is! Map) {
      throw _invalid('source', 'expected a map, got ${raw.runtimeType}');
    }
    final m = raw.cast<Object?, Object?>();
    for (final key in _sourceKeys) {
      if (!m.containsKey(key)) throw _invalid(key, 'missing');
    }
    for (final key in m.keys) {
      if (!_sourceKeys.contains(key)) throw _invalid('$key', 'unknown key');
    }

    final id = m['id'];
    if (id is! String) throw _invalid('id', 'expected String, got $id');
    final title = m['title'];
    if (title is! String) {
      throw _invalid('title', 'expected String, got $title');
    }
    final applicationName = m['applicationName'];
    if (applicationName is! String?) {
      throw _invalid(
          'applicationName', 'expected String?, got $applicationName');
    }
    final sourceWidth = m['sourceWidth'];
    if (sourceWidth is! int) {
      throw _invalid('sourceWidth', 'expected int, got $sourceWidth');
    }
    final sourceHeight = m['sourceHeight'];
    if (sourceHeight is! int) {
      throw _invalid('sourceHeight', 'expected int, got $sourceHeight');
    }
    final thumbnailPng = m['thumbnailPng'];
    if (thumbnailPng is! Uint8List?) {
      throw _invalid('thumbnailPng', 'expected Uint8List?, got $thumbnailPng');
    }

    return XScreenSource(
      id: id,
      kind: switch (m['kind']) {
        'display' => XScreenSourceKind.display,
        'window' => XScreenSourceKind.window,
        final other => throw _invalid('kind', 'expected a kind, got $other'),
      },
      title: title,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      thumbnailPng: thumbnailPng,
      applicationName: applicationName,
    );
  }

  static XScreenSourcesException _invalid(Object? field, String detail) =>
      XScreenSourcesException('invalid_response', '$field: $detail');
}
